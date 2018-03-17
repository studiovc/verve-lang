module Renamer.Renamer
  ( renameImport
  , renameStmt
  , renameStmts
  ) where

import Absyn.Untyped
import Renamer.Env
import Renamer.State
import Typing.TypeError
import Util.Error

import Control.Monad (foldM, zipWithM)
import Control.Monad.Except (withExcept)
import Control.Monad.State (mapStateT)
import Data.List (intercalate)


-- TODO: This will need scoping, otherwise the following will fail
--
-- module A { enum C { D } }
-- module B { enum D { C } }
--
-- then in a module C, when you import both A and B, the following will
-- be renamed from
--
-- f() -> (C, D) { (D, C) }
--
-- to:
--
-- f() -> (B.C, B.D) { (B.D, B.C) }
--
-- instead of:
--
-- f() -> (A.C, B.D) { (A.D, B.C) }


-- ENTRY POINT

renameStmts :: String -> Env -> [Stmt] -> Result (Env, [Stmt])
renameStmts modName env stmts =
  runRn modName $ foldAcc r_stmt env stmts

renameStmt :: String -> Env -> Stmt -> Result (Env, Stmt)
renameStmt modName env stmt =
  runRn modName $ r_stmt env stmt

renameImport :: Env -> Env -> Import -> (Env, [String])
renameImport env impEnv (Import isGlobal mod alias items) =
  let (envBinds, renamedImports) = binds
   in (extendEnv env envBinds, renamedImports)
  where
    binds =
      let f b@(External (m, n)) = (((modAlias, n), b), joinName (m, n))
          f _ = undefined
       in unzip $ map f filteredNames

    filteredNames =
      let f = maybe (const True) mkFilter items
       in filter f unfilteredNames

    mkFilter items =
      let items' = concatMap getItemNames items
          f (External (_, n)) = elem n items'
          f _ = undefined
       in f

    getItemNames (ImportValue v) = [v]
    getItemNames (ImportType n vs) = n : vs

    unfilteredNames =
      let f (Internal _) = False
          f (External (m, _)) = m == modName
       in filter f $ map snd $ getBinds impEnv

    modName = intercalate "." mod

    modAlias =
      if isGlobal
         then Nothing
         else Just $ maybe modName id alias


-- ABSYN RENAMERS

r_stmts :: Env -> [Stmt] -> Rn [Stmt]
r_stmts env stmts = snd <$> foldAcc r_stmt env stmts


r_stmt :: Env -> Stmt -> Rn (Env, Stmt)
r_stmt env (Expr expr) = do
  expr' <- r_expr env expr
  return (env, Expr expr')

r_stmt env (Decl decl) = do
  (env', decl') <- r_decl env decl
  return (env', Decl decl')

r_decl ::Env -> Decl -> Rn (Env, Decl)
r_decl env (Enum name gen ctors) = do
  (envWithType, name') <- addLocal env name
  envWithGenerics <- foldM addInternal envWithType gen
  (envWithCtors, ctors') <- r_ctors envWithGenerics ctors
  return (envWithCtors, Enum name' gen ctors')

r_decl env (FnStmt fn) = do
  (env', fn') <- r_fn env fn
  return (env', FnStmt fn')

r_decl env (Let (name, ty) expr) = do
  ty' <- r_type env ty
  envWithVar <- addInternal env name
  expr' <- r_expr envWithVar expr
  return (envWithVar, Let (name, ty') expr')

r_decl env (Class name vars methods) = do
  (envWithClass, name') <- addLocal env name
  (envWithVars, vars') <- r_fnParams envWithClass vars
  (envWithMethods, names') <- foldAcc r_methodSig envWithVars methods
  methods' <- zipWithM (r_methodImp envWithMethods) names' methods
  return (envWithMethods, Class name' vars' methods')

r_decl env (Operator assoc prec gen lhs op rhs retType body) = do
  prec' <- r_prec env prec
  (envWithOp, op') <- addLocal env op
  (envWithGen, gen') <- r_generics envWithOp gen
  retType' <- r_type envWithGen retType

  (envWithParams, [lhs', rhs']) <- r_fnParams envWithGen [lhs, rhs]
  body' <- r_stmts envWithParams body

  let op = Operator assoc prec' gen' lhs' op' rhs' retType' body'
   in return (envWithOp, op)

r_decl env (Interface name param methods) = do
  (envWithIntf, name') <- addLocal env name
  (envWithoutParam, methods') <- foldAcc (r_intfField param) envWithIntf methods
  return (envWithoutParam, Interface name' param methods')

r_decl env (Implementation name gen ty implMethods) = do
  name' <- lookupIdent [name] env
  (envWithGen, gen') <- r_generics env gen
  ty' <- r_type envWithGen ty
  implMethods' <- mapM (r_implItem envWithGen) implMethods
  return (env, Implementation name' gen' ty' implMethods')

r_decl env (TypeAlias aliasName aliasVars aliasType) = do
  (envWithAlias, aliasName') <- addLocal env aliasName
  envWithVars <- foldM addInternal envWithAlias aliasVars
  aliasType' <- r_type envWithVars aliasType
  return (envWithAlias, TypeAlias aliasName' aliasVars aliasType')


r_implItem :: Env -> ImplementationItem -> Rn ImplementationItem
r_implItem env (ImplVar (name, expr)) = do
  name' <- lookupIntfMethod name env
  expr' <- r_expr env expr
  return $ ImplVar (name', expr')

r_implItem env (ImplFunction implName implParams implBody) = do
  implName' <- lookupIntfMethod implName env
  envWithParams <- foldM addInternal env implParams
  implBody' <- r_stmts envWithParams implBody
  return (ImplFunction implName' implParams implBody')

r_implItem env (ImplOperator lhs op rhs body) = do
  op' <- lookupIntfMethod op env
  envWithParams <- foldM addInternal env [lhs, rhs]
  body' <- r_stmts envWithParams body
  return (ImplOperator lhs op' rhs body')

lookupIntfMethod :: String -> Env -> Rn String
lookupIntfMethod name env =
  mapStateT (withExcept $ \_ -> Error (ExtraneousImplementation name)) $ lookupIdent [name] env

r_expr :: Env -> Expr -> Rn Expr
r_expr _ (Literal l) =
  return (Literal l)

r_expr env (ParenthesizedExpr expr) =
  ParenthesizedExpr <$> r_expr env expr

r_expr env (FnExpr fn) = do
  FnExpr . snd <$> r_fn env fn

r_expr env (Ident name ty) = do
  name' <- lookupIdent name env
  ty' <- r_type env ty
  return (Ident [name'] ty')

r_expr env (Match expr cases) = do
  expr' <- r_expr env expr
  cases' <- mapM (r_case env) cases
  return (Match expr' cases')

r_expr env (If cond conseq alt) = do
  cond' <- r_expr env cond
  conseq' <- r_stmts env conseq
  alt' <- r_stmts env alt
  return (If cond' conseq' alt')

r_expr env (Call callee _ tyArgs vArgs) = do
  callee' <- r_expr env callee
  tyArgs' <- mapM (r_type env) tyArgs
  vArgs' <- mapM (r_expr env) vArgs
  return (Call callee' [] tyArgs' vArgs')

r_expr env (BinOp _ _ lhs op rhs) = do
  lhs' <- r_expr env lhs
  op' <- lookupIdent [op] env
  rhs' <- r_expr env rhs
  return (BinOp [] [] lhs' op' rhs')

r_expr env (Record fields) = do
  fields' <- mapM (sequence . fmap (r_expr env)) fields
  return (Record fields')

r_expr env (List ty items) = do
  items' <- mapM (r_expr env) items
  return (List ty items')

r_expr env (FieldAccess expr ty field) = do
  expr' <- r_expr env expr
  ty' <- r_type env ty
  return (FieldAccess expr' ty' field)

r_expr env (Negate constrArgs expr) =
  Negate constrArgs <$> r_expr env expr

-- Expressions that can only be generated by the compiler after Type Checking
r_expr _ VoidExpr = undefined
r_expr _ (TypeCall {}) = undefined


r_case :: Env -> Case -> Rn Case
r_case env (Case pat body) = do
  (env', pat') <- r_pat env pat
  body' <- r_stmts env' body
  return (Case pat' body')


r_pat :: Env -> Pattern -> Rn (Env, Pattern)
r_pat env PatDefault =
  return (env, PatDefault)

r_pat env (PatLiteral l) =
  return (env, PatLiteral l)

r_pat env (PatVar v) = do
  env' <- addInternal env v
  return (env', PatVar v)

r_pat env (PatRecord fields) = do
  (env', fields') <- foldAcc aux env fields
  return (env', PatRecord $ reverse fields')
  where
    aux env (key, pat) = do
      (env', pat') <- r_pat env pat
      return (env', (key, pat'))

r_pat env (PatList pats rest) = do
  (env', pats') <- foldAcc r_pat env pats
  env'' <- case rest of
              NamedRest n -> addInternal env' n
              _ -> return env'
  return (env'', PatList (reverse pats') rest)

r_pat env (PatCtor name args) = do
  name' <- lookupIdent [name] env
  (env', args') <- foldAcc r_pat env args
  return (env', PatCtor name' args')

r_type :: Env -> Type -> Rn Type
r_type _ TVoid =
  return TVoid

r_type _ TPlaceholder =
  return TPlaceholder

r_type env (TName name) = do
  name' <- lookupIdent [name] env
  return $ TName name'

r_type env (TApp ty args) = do
  ty' <- r_type env ty
  args' <- mapM (r_type env) args
  return $ TApp ty' args'

r_type env (TArrow params ret) = do
  params' <- mapM (r_type env) params
  ret' <- r_type env ret
  return $ TArrow params' ret'

r_type env (TRecord fields) = do
  fields' <- mapM (sequence . fmap (r_type env)) fields
  return $ TRecord fields'

r_fn :: Env -> Function -> Rn (Env, Function)
r_fn env fn = do
  (envWithFn, name') <- addLocal env (name fn)
  fn' <- r_fnBase name' envWithFn fn
  return (envWithFn, fn')

r_fnBase :: String -> Env -> Function -> Rn Function
r_fnBase name' env (Function _ gen params retType body) = do
  (envWithGenerics, gen') <- r_generics env gen
  (envWithParams, params') <- r_fnParams envWithGenerics params
  retType' <- r_type envWithGenerics retType
  body' <- r_stmts envWithParams body
  return $ Function name' gen' params' retType' body'


r_fnParams :: Env -> [Param] -> Rn (Env, [Param])
r_fnParams = foldAcc r_fnParam


r_fnParam :: Env -> Param -> Rn (Env, Param)
r_fnParam env (name, ty) = do
  envWithParam <- addInternal env name
  ty' <- r_type env ty
  return (envWithParam, (name, ty'))


r_generics :: Env -> Generics -> Rn (Env, Generics)
r_generics = foldAcc r_generic


r_generic :: Env -> (Name, [Name]) -> Rn (Env, (Name, [Name]))
r_generic env (name, bounds) = do
  envWithTypeVar <- addInternal env name
  bounds' <- mapM (flip lookupIdent env . (:[])) bounds
  return (envWithTypeVar, (name, bounds'))


r_ctors :: Env -> [DataCtor] -> Rn (Env, [DataCtor])
r_ctors = foldAcc r_ctor


r_ctor :: Env -> DataCtor -> Rn (Env, DataCtor)
r_ctor env (name, args) = do
  (env', name') <- addLocal env name
  args' <- sequence $ args >>= return . mapM (r_type env)
  return (env', (name', args'))


foldAcc :: Monad m => (a -> b -> m (a, c)) -> a -> [b] -> m (a, [c])
foldAcc f a bs =
  let aux (a, cs) b = do
        (a', c) <- f a b
        return (a', c : cs)
   in fmap reverse <$> foldM aux (a, []) bs

r_prec :: Env -> Precedence -> Rn Precedence
r_prec _ (PrecValue v) =
  return $ PrecValue v

r_prec env (PrecHigher name) = do
  name' <- lookupIdent [name] env
  return (PrecHigher name')

r_prec env (PrecLower name) = do
  name' <- lookupIdent [name] env
  return (PrecLower name')

r_prec env (PrecEqual name) = do
  name' <- lookupIdent [name] env
  return (PrecEqual name')


r_methodSig :: Env -> Function -> Rn (Env, String)
r_methodSig env fn = do
  addLocal env (name fn)

r_methodImp :: Env -> String -> Function -> Rn Function
r_methodImp env name' fn = do
  envWithSelf <- addInternal env "self"
  r_fnBase name' envWithSelf fn

r_intfField :: String -> Env -> InterfaceItem -> Rn (Env, InterfaceItem)
r_intfField param env (IntfVar (name, ty)) = do
  envWithParam <- addInternal env param
  ty' <- r_type envWithParam ty
  (envWithField, name') <- addLocal env name
  return (envWithField, IntfVar (name', ty'))

r_intfField param env (IntfOperator assoc prec lhs op rhs ret) = do
  envWithParam <- addInternal env param
  prec' <- r_prec env prec
  (envWithOp, op') <- addLocal env op
  lhs' <- r_type envWithParam lhs
  rhs' <- r_type envWithParam rhs
  ret' <- r_type envWithParam ret
  let op = IntfOperator assoc prec' lhs' op' rhs' ret'
   in return (envWithOp, op)
