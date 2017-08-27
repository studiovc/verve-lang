{-# LANGUAGE NamedFieldPuns #-}

module Naming
  ( balance
  , balanceStmt
  , Env
  , defaultEnv
  ) where

import Absyn
import Error

import Control.Monad (foldM)

type PrecInt = Integer
type OpInfo = (Associativity, PrecInt)

data NameError
  = UnknownOperator Name
  | PrecedenceError Name Name
  deriving (Show)

instance ErrorT NameError where
  kind _ = "NameError"

newtype Env = Env [(Name, OpInfo)]

defaultEnv :: Env
defaultEnv = Env []

addOpInfo :: Env -> (Name, OpInfo) -> Env
addOpInfo (Env env) info = Env (info : env)

getOpInfo :: Name -> Env -> Result OpInfo
getOpInfo name (Env env) =
  case lookup name env of
    Just info -> return info
    Nothing -> mkError $ UnknownOperator name

getPrec :: Name -> Env -> Result PrecInt
getPrec name env = snd <$> getOpInfo name env

balance :: Module Name UnresolvedType -> Result (Module Name UnresolvedType)
balance (Module stmts) = do
  (_, stmts') <- n_stmts defaultEnv stmts
  return $ Module stmts'

balanceStmt :: Env -> Stmt Name UnresolvedType -> Result (Env, Stmt Name UnresolvedType)
balanceStmt = n_stmt

n_stmts :: Env -> [Stmt Name UnresolvedType] -> Result (Env, [Stmt Name UnresolvedType])
n_stmts env stmts = do
  (env', stmts') <- foldM aux (env, []) stmts
  return (env', reverse stmts')
    where
      aux (env, stmts) stmt = do
        (env', stmt') <- n_stmt env stmt
        return (env', stmt' : stmts)

n_stmt :: Env -> Stmt Name UnresolvedType -> Result (Env, Stmt Name UnresolvedType)
n_stmt env op@(Operator { opAssoc, opPrec, opName, opBody }) = do
  opPrec' <- prec env opPrec
  let env' = addOpInfo env (opName, (opAssoc, opPrec'))
  (_, opBody') <- n_stmts env' opBody
  return (env', op { opBody = opBody' })
n_stmt env (FnStmt fn) = do
  fn' <- n_fn env fn
  return (env, FnStmt fn')
n_stmt env (Let x expr) = do
  expr' <- n_expr env expr
  return (env, Let x expr')
n_stmt env (Class name vars methods) = do
  methods' <- mapM (n_fn env) methods
  return (env, Class name vars methods')
n_stmt env (Expr expr) = do
  expr' <- n_expr env expr
  return (env, Expr expr')
n_stmt env stmt = return (env, stmt)

prec :: Env -> Precedence -> Result PrecInt
prec _ (PrecValue n) = return n
prec env (PrecEqual n) =  getPrec n env
prec env (PrecHigher n) =  (+) 1 <$> getPrec n env
prec env (PrecLower n) =  (-) 1 <$> getPrec n env

n_fn :: Env -> Function Name UnresolvedType -> Result (Function Name UnresolvedType)
n_fn env fn = do
  (_, body') <- n_stmts env (body fn)
  return fn { body = body' }

n_expr :: Env -> Expr Name UnresolvedType -> Result (Expr Name UnresolvedType)
n_expr env (BinOp _ ll lop (BinOp _ rl rop rr)) = do
  ll' <- n_expr env ll
  rl' <- n_expr env rl
  rr' <- n_expr env rr
  c <- comparePrec env lop rop
  return $ case c of
    PLeft ->
      BinOp [] (BinOp [] ll' lop rl') rop rr'
    PRight ->
      BinOp [] ll' lop (BinOp [] rl' rop rr')
n_expr _ expr = return expr

data Prec
  = PLeft
  | PRight

comparePrec :: Env -> Name -> Name -> Result Prec
comparePrec env l r = do
  (lAssoc, lPrec) <- getOpInfo l env
  (rAssoc, rPrec) <- getOpInfo r env
  case (compare lPrec rPrec, lAssoc, rAssoc) of
    (LT, _, _) -> return PRight
    (GT, _, _) -> return PLeft
    (EQ, AssocLeft, AssocLeft) -> return PLeft
    (EQ, AssocRight, AssocRight) -> return PRight
    (EQ, _, _) -> mkError $ PrecedenceError l r