module Lib.Registry
  ( registry

  , isType
  , isValue
  , isCtor
  , isInternal

  , name
  , decl
  , impl
  ) where

import Typing.Types hiding (list)
import Interpreter.Builtin
import Interpreter.Value

import qualified Typing.Types as Types (list)

import Control.Monad.Writer (Writer, execWriter, tell)

data Entry
  = EType String Type
  | EVal String Type Value
  | ECtor String Type
  | EInternal String Value

-- REGISTRY
type WReg = Writer [Entry] ()

ty :: String -> Type -> WReg
ty name ty = tell [EType name ty]

val :: String -> Type -> Value -> WReg
val name ty val = tell [EVal name ty val]

ctor :: String -> Type -> WReg
ctor name ty = tell [ECtor name ty]

internal :: String -> Value -> WReg
internal name val = tell [EInternal name val]

type Registry = [Entry]

registry :: Registry
registry = execWriter $ do
  ty "Int" int
  ty "Float" float
  ty "Char" char
  ty "String" string
  ty "Void" void
  ty "List" (forall [T] $ list T)
  ty "Bool" bool

  val "string_print" ([string] ~> void) string_print
  val "int_add" ([int, int] ~> int) int_add
  val "int_sub" ([int, int] ~> int) int_sub
  val "int_mul" ([int, int] ~> int) int_mul
  val "int_div" ([int, int] ~> int) int_div
  val "int_mod" ([int, int] ~> int) int_mod
  val "int_neg" ([int] ~> int) int_neg
  val "int_lt" ([int, int] ~> bool) int_lt
  val "int_gt" ([int, int] ~> bool) int_gt
  val "int_to_string" ([int] ~> string) int_to_string
  val "char_to_int" ([char] ~> int) char_to_int

  val "readFile" ([string] ~> string) read_file

  -- Float
  val "sqrt" ([float] ~> float) sqrt'
  val "ceil" ([float] ~> int) ceil'

  -- String
  val "strlen" ([string] ~> int) strlen
  val "substr" ([string, int, int] ~> string) substr
  val "charAt" ([string, int] ~> char) charAt

  ctor "True" bool
  ctor "False" bool
  ctor "Nil" (forall [T] $ list T)
  ctor "Cons" (forall [T] $ [var T, list T] ~> list T)

  internal "#fieldAccess" fieldAccess
  {-internal "#unwrapClass" unwrapClass-}

-- FILTERS
isValue :: Entry -> Bool
isValue (EVal {}) = True
isValue (ECtor {}) = False
isValue (EType {}) = False
isValue (EInternal {}) = False

isCtor :: Entry -> Bool
isCtor (EVal {}) = False
isCtor (ECtor {}) = True
isCtor (EType {}) = False
isCtor (EInternal {}) = False

isType :: Entry -> Bool
isType (EVal {}) = False
isType (ECtor {}) = False
isType (EType {}) = True
isType (EInternal {}) = False

isInternal :: Entry -> Bool
isInternal (EVal {}) = False
isInternal (ECtor {}) = False
isInternal (EType {}) = False
isInternal (EInternal {}) = True

-- TRANSFORMERS
name :: Entry -> String
name (EVal name _ _) = name
name (EType name _) = name
name (ECtor name _) = name
name (EInternal {}) = undefined

decl :: Entry -> (String, Type)
decl (EVal name ty _) = (name, ty)
decl (EType name ty) = (name, ty)
decl (ECtor name ty) = (name, ty)
decl (EInternal {}) = undefined

impl :: Entry -> (String, Value)
impl (EVal name _ val) = (name, val)
impl (EType {}) = undefined
impl (ECtor {}) = undefined
impl (EInternal name val) = (name, val)

-- Helpers for better syntax for expressing types

list :: FakeVar -> Type
list ty = Types.list (var ty)

forall :: [FakeVar] -> Type -> Type
forall vs (Fun [] params args) =
  let vs' = map (flip (,) [] . tyvar) vs
   in Fun vs' params args

forall vs ty =
  TyAbs (map tyvar vs) ty

var :: FakeVar -> Type
var name = Var (tyvar name) []

