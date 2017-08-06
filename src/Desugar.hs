module Desugar
  ( desugar
  , desugarStmt
  ) where

import Absyn
import Types
import qualified CoreAbsyn as CA

desugar :: Module Id -> CA.Expr
desugar = d_stmts . stmts

desugarStmt :: Stmt Id -> CA.Expr
desugarStmt stmt =
  let (x, v) = d_stmt stmt
   in CA.Let  [(x, v)] (CA.Var x)

d_stmts :: [Stmt Id] -> CA.Expr
d_stmts [] = CA.Void
d_stmts [s] = snd $ d_stmt s
d_stmts (s:ss) =
  CA.Let [d_stmt s] (d_stmts ss)

d_stmt :: Stmt Id -> CA.Bind
d_stmt (Expr e) = (Id "" void, d_expr e)
d_stmt (FnStmt fn) = (name fn, d_fn fn)

d_fn :: Function Id -> CA.Expr
d_fn fn@(Function { params=[] }) = d_fn (fn { params = [("", void)] })
d_fn fn =
  foldr CA.Lam (d_stmts $ body fn) (map (uncurry Id) $ params fn)

d_expr :: Expr Id -> CA.Expr
d_expr VoidExpr = CA.Void
d_expr (Literal l) = CA.Lit l
d_expr (Ident id) = CA.Var id
d_expr (App callee []) = d_expr (App callee [VoidExpr])
d_expr (App callee args) =
  foldl mkApp (d_expr callee) args
    where
      mkApp :: CA.Expr -> Expr Id -> CA.Expr
      mkApp callee arg =
        CA.App callee (d_expr arg)