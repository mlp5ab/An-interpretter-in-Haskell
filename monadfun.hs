import System.IO
import System.Environment
import System.Exit(exitFailure, exitSuccess, exitWith)
import Debug.Trace
import Data.List (find, lookup)
import qualified Data.List as List
import Data.Map (Map)
import qualified Data.Map as Map
import Control.Exception (try, SomeException)
import Control.Monad.State
import Control.Monad (foldM)
import Control.Monad.Error
import Data.Int


-- This State Transformer holds the magic that makes this program run. It abstracts away the IO monad and combines it with the State Monad that holds our store.
type StateWithIO s a = StateT s IO a

-- Helper type declarations for readability
type Type = String
type Name = String
type FormalName = String
type MethodDefiner = String
type LineNo = Int
type MethodType = Identifier
type MethodIdentifier = Identifier
type TypeIdentifier = Identifier
type NameIdentifier = Identifier
type Child = String
type Parent = String

-- The main structure of our parsing and interpretting logic
data Class = Class String [Feature]
        |   AstClass LineNo String [Feature] (Maybe TypeIdentifier) deriving(Show)
data Feature = Attribute Name Type (Maybe Expr)
        |   AstAttribute NameIdentifier TypeIdentifier (Maybe Expr)
        |   Method Name [FormalName] MethodDefiner Expr
        |   AstMethod NameIdentifier [Formal] MethodType Expr
        deriving(Show)
data Formal = Formal Identifier Identifier deriving(Show)
data Identifier = Identifier LineNo Name deriving(Show)
data Expr = Integer LineNo Type Int
        |   Str LineNo Type String
        |   TrueBool LineNo Type
        |   FalseBool LineNo Type
        |   Equal LineNo Type Expr Expr
        |   LessThan LineNo Type Expr Expr
        |   LessEqual LineNo Type Expr Expr
        |   Negate LineNo Type Expr
        |   IsVoid LineNo Type Expr
        |   Not LineNo Type Expr
        |   Times LineNo Type Expr Expr
        |   Divide LineNo Type Expr Expr
        |   Plus LineNo Type Expr Expr
        |   Minus LineNo Type Expr Expr
        |   IdentExpr LineNo Type Identifier
        |   New LineNo Type Identifier
        |   Assign LineNo Type Identifier Expr
        |   While LineNo Type Expr Expr
        |   If LineNo Type Expr Expr Expr
        |   Block LineNo Type [Expr]
        |   SelfDispatch LineNo Type Identifier [Expr]
        |   DynamicDispatch LineNo Type Expr MethodIdentifier [Expr]
        |   StaticDispatch LineNo Type Expr TypeIdentifier MethodIdentifier [Expr]
        |   Let LineNo Type [LetBinding] Expr
        |   Case LineNo Type Expr [CaseElement]
        |   Internal LineNo Type Name
    deriving (Show)

data LetBinding = LetBinding NameIdentifier TypeIdentifier (Maybe Expr) deriving(Show)
data CaseElement = CaseElement NameIdentifier TypeIdentifier Expr deriving(Show)

data Program = Program [Class] deriving(Show)

type ClassMap = [Class]
type ImpMap = [Class]
type ParentMap = [(Child, Parent)]

------- Interpreter types -------
type Location = Int

type Store = Map Location Value
type Environment = Map Name Location

type ProgramState = Store

-- Void algebraic data type for default Void value. Perhaps think about using a maybe for Object only
data Value = CoolBool Bool
        | CoolInt Int32
        | CoolString Int String
        | Object Type (Map Name Location)
        | Void
        deriving (Show)


---------------------------- Class Map ---------------------------------------------
parse_cm [] = error "empty input file"
parse_cm ("class_map": num_classes : tl) =
    let nc = read num_classes :: Int
    in parse_cm_class nc tl

parse_cm_class _ [] = error "empty class in class map"
parse_cm_class 0 _  = []
parse_cm_class n (cname : num_attr : tl) =
    let na = read num_attr :: Int
        (attributes, rem_input) = parse_cm_attribute na tl
    in (Class cname attributes) : parse_cm_class (n-1) rem_input

parse_cm_attribute _ [] = error "empty attribute in class map"
parse_cm_attribute 0 rem_input = ([], rem_input)
parse_cm_attribute n xs = case xs of
    ("initializer" : attr_name : attr_type : tl) ->
        let (expr, rem_input) = parse_expr tl
            (attrs, fin_rem_input) = parse_cm_attribute (n-1) rem_input
        in ((Attribute attr_name attr_type (Just expr) ) : attrs, fin_rem_input)
    ("no_initializer" : attr_name : attr_type : tl) ->
        let (attrs, rem_input) = parse_cm_attribute (n-1) tl
        in ((Attribute attr_name attr_type Nothing) : attrs, rem_input)

------------------------ Implementation Map -----------------------------------------
parse_imp_map [] = error "empty input file"
parse_imp_map ("implementation_map" : num_classes : tl) =
    let nc = read num_classes :: Int
    in parse_imp_class nc tl
-- We have to traverse throught the file until we find the imp_map
parse_imp_map (hd:tl) = parse_imp_map tl

parse_imp_class _ [] = error "empty class in imp map"
parse_imp_class 0 _ = []
parse_imp_class n (cname : num_methods : tl) =
    let nm = read num_methods :: Int
        (methods, rem_input) = parse_imp_methods nm tl
    in (Class cname methods) : parse_imp_class (n-1) rem_input

parse_imp_methods _ [] = error "empty method in implementation map"
parse_imp_methods 0 rem_input = ([], rem_input)
parse_imp_methods n xs = case xs of
    (meth_name : num_formals : tl) ->
        let nf = read num_formals :: Int
            (formals, rem_input) = parse_formals_list nf tl
            (meth_owner : rem_input_2) = rem_input
            (expr, rem_input_3) = parse_expr rem_input_2
            (methods, fin_rem_input) = parse_imp_methods (n-1) rem_input_3
        in ((Method meth_name formals meth_owner expr) : methods, fin_rem_input)

parse_formals_list 0 xs = ([], xs)
parse_formals_list n xs = case xs of
    (formal_name : tl) ->
        let (formals, rem_input) = parse_formals_list (n-1) tl
        in (formal_name : formals, rem_input)
    x -> error "this should never happen in parse formals"

--------------------------- Parent Map -------------------------------------------

-- Makes and association list in the form [(subclass, superclass)]
parse_parent_map_and_ast [] = error "empty input file"
parse_parent_map_and_ast ("parent_map" : num_relations : tl) =
    let num_rel = read num_relations :: Int
        (relations, rem_lines) = parse_parent_map_relations num_rel tl
        ast = parse_ast rem_lines
    in (relations, ast)
parse_parent_map_and_ast (hd:tl) = parse_parent_map_and_ast tl

parse_parent_map_relations 0 left = ([], left)
parse_parent_map_relations n (child:parent:tl) =
    let (relations, rem_lines) = parse_parent_map_relations (n-1) tl
    in ((child, parent) : relations, rem_lines)
parse_parent_map_relations _ _ = error "this should not happen in parent map relations"

-------------------------- Annotated Abstract Syntax tree ----------------------------

parse_ast [] = error "annotated ast not in input"
parse_ast (num_classes : tl) =
    let n = read num_classes :: Int
        classes = parse_ast_classes n tl
    in Program classes

parse_ast_classes 0 _ = []
parse_ast_classes n (line_no : cname : "inherits" : parent_line_no : parent_name : num_feats : tl) =
    let ln = read line_no :: Int
        pln = read parent_line_no :: Int
        nf = read num_feats :: Int
        (features, rem_lines) = parse_ast_features nf tl
        classes = parse_ast_classes (n-1) rem_lines
    in ( (AstClass ln cname features (Just (Identifier pln parent_name))) : classes )
parse_ast_classes n (line_no : cname : "no_inherits" : num_feats : tl) =
    let ln = read line_no :: Int
        nf = read num_feats :: Int
        (features, rem_lines) = parse_ast_features nf tl
        classes = parse_ast_classes (n-1) rem_lines
    in ( (AstClass ln cname features Nothing) : classes)

parse_ast_features 0 last = ([], last)
parse_ast_features n ("attribute_no_init" : line_no : fname : type_line_no : type_name : tl) =
    let ln = read line_no :: Int
        tln = read type_line_no :: Int
        (features, rem_lines) = parse_ast_features (n-1) tl
    in ((AstAttribute (Identifier ln fname) (Identifier tln type_name) Nothing ) : features, rem_lines)
parse_ast_features n ("attribute_init" : line_no : fname : type_line_no : type_name : tl) =
    let ln = read line_no :: Int
        tln = read type_line_no :: Int
        (expr, rem_lines) = parse_expr tl
        (features, rem_lines_2) = parse_ast_features (n-1) rem_lines
    in ((AstAttribute (Identifier ln fname) (Identifier tln type_name) (Just expr)) : features, rem_lines_2)
parse_ast_features n ("method" : line_no : fname : num_formals : tl) =
    let ln = read line_no :: Int
        nf = read num_formals :: Int
        (formals, rem_lines) = parse_formal_identifiers nf tl
        (type_line_no : type_name : rem_lines_2) = rem_lines
        tln = read type_line_no :: Int
        (expr, rem_lines_3) = parse_expr rem_lines_2
        (features, rem_lines_4) = parse_ast_features (n-1) rem_lines_3
    in ((AstMethod (Identifier ln fname) formals (Identifier tln type_name) expr) : features, rem_lines_4)

parse_formal_identifiers 0 last = ([], last)
parse_formal_identifiers n (line_no : fname : type_line_no : type_name : tl) =
    let ln = read line_no :: Int
        tln = read type_line_no :: Int
        (formals, rem_lines) = parse_formal_identifiers (n-1) tl
    in ( (Formal (Identifier ln fname) (Identifier tln type_name)) : formals, rem_lines)

------------------------ Parse Expressions -------------------------------------------------

parse_expr xs = case xs of
    -- Integer, String, and Bool
    (line_no : expr_type : "integer" : val : tl) ->
        let n = read line_no :: Int
            v = read val :: Int
        in ((Integer n expr_type v), tl)
    (line_no : expr_type : "string" : val : tl) ->
        let n = read line_no :: Int
        in ((Str n expr_type val), tl)
    (line_no : expr_type : "true" : tl) ->
        let n = read line_no :: Int
        in ((TrueBool n expr_type), tl)
    (line_no : expr_type : "false" : tl) ->
        let n = read line_no :: Int
        in ((FalseBool n expr_type), tl)
    -- LT, LE, EQ
    (line_no : expr_type : "eq" : tl) ->
        let n = read line_no :: Int
            (expr1, rem_input_1) = parse_expr tl
            (expr2, rem_input_2) = parse_expr rem_input_1
        in ((Equal n expr_type expr1 expr2), rem_input_2)
    (line_no : expr_type : "lt" : tl) ->
        let n = read line_no :: Int
            (expr1, rem_input_1) = parse_expr tl
            (expr2, rem_input_2) = parse_expr rem_input_1
        in ((LessThan n expr_type expr1 expr2), rem_input_2)
    (line_no : expr_type : "le" : tl) ->
        let n = read line_no :: Int
            (expr1, rem_input_1) = parse_expr tl
            (expr2, rem_input_2) = parse_expr rem_input_1
        in ((LessEqual n expr_type expr1 expr2), rem_input_2)
    -- Not, Negate, IsVoid
    (line_no : expr_type : "negate" : tl) ->
        let n = read line_no :: Int
            (expr, rem_input) = parse_expr tl
        in ((Negate n expr_type expr), rem_input)
    (line_no : expr_type : "not" : tl) ->
        let n = read line_no :: Int
            (expr, rem_input) = parse_expr tl
        in ((Not n expr_type expr), rem_input)
    (line_no : expr_type : "isvoid" : tl) ->
        let n = read line_no :: Int
            (expr, rem_input) = parse_expr tl
        in ((IsVoid n expr_type expr), rem_input)
    -- Plus, Minus, Times, Divide
    (line_no : expr_type : "times" : tl) ->
        let n = read line_no :: Int
            (expr1, rem_input_1) = parse_expr tl
            (expr2, rem_input_2) = parse_expr rem_input_1
        in ((Times n expr_type expr1 expr2), rem_input_2)
    (line_no : expr_type : "divide" : tl) ->
        let n = read line_no :: Int
            (expr1, rem_input_1) = parse_expr tl
            (expr2, rem_input_2) = parse_expr rem_input_1
        in ((Divide n expr_type expr1 expr2), rem_input_2)
    (line_no : expr_type : "plus" : tl) ->
        let n = read line_no :: Int
            (expr1, rem_input_1) = parse_expr tl
            (expr2, rem_input_2) = parse_expr rem_input_1
        in ((Plus n expr_type expr1 expr2), rem_input_2)
    (line_no : expr_type : "minus" : tl) ->
        let n = read line_no :: Int
            (expr1, rem_input_1) = parse_expr tl
            (expr2, rem_input_2) = parse_expr rem_input_1
        in ((Minus n expr_type expr1 expr2), rem_input_2)
    -- Identifier, New, Assign
    (line_no : expr_type : "identifier" : tl) ->
        let n = read line_no :: Int
            (ident, rem_input) = parse_identifier tl
        in ((IdentExpr n expr_type ident), rem_input)
    (line_no : expr_type : "new" : tl) ->
        let n = read line_no :: Int
            (ident, rem_input) = parse_identifier tl
        in ((New n expr_type ident), rem_input)
    (line_no : expr_type : "assign" : tl) ->
        let n = read line_no :: Int
            (ident, rem_input_1) = parse_identifier tl
            (expr, rem_input_2) = parse_expr rem_input_1
        in ((Assign n expr_type ident expr), rem_input_2)
    -- While, If
    (line_no : expr_type : "while" : tl) ->
        let n = read line_no :: Int
            (expr1, rem_input_1) = parse_expr tl
            (expr2, rem_input_2) = parse_expr rem_input_1
        in ((While n expr_type expr1 expr2), rem_input_2)
    (line_no : expr_type : "if" : tl) ->
        let n = read line_no :: Int
            (expr1, rem_input_1) = parse_expr tl
            (expr2, rem_input_2) = parse_expr rem_input_1
            (expr3, rem_input_3) = parse_expr rem_input_2
        in ((If n expr_type expr1 expr2 expr3), rem_input_3)
    -- Block
    (line_no : expr_type : "block" : num_exprs : tl) ->
        let n = read line_no :: Int
            n_exprs = read num_exprs :: Int
            (expr_list, rem_input) = parse_expr_list n_exprs tl
        in ((Block n expr_type expr_list), rem_input)
    -- Dispatch
    (line_no : expr_type : "self_dispatch" : tl) ->
        let n = read line_no :: Int
            (ident, rem_input) = parse_identifier tl
            (num_exprs : rem_input_1) = rem_input
            n_exprs = read num_exprs :: Int
            (expr_list, rem_input_2) = parse_expr_list n_exprs rem_input_1
        in ((SelfDispatch n expr_type ident expr_list), rem_input_2)
    (line_no : expr_type : "dynamic_dispatch" : tl) ->
        let n = read line_no :: Int
            (expr, rem_input_1) = parse_expr tl
            (ident, rem_input_2) = parse_identifier rem_input_1
            (num_exprs : rem_input_3) = rem_input_2
            n_exprs = read num_exprs :: Int
            (expr_list, rem_input_4) = parse_expr_list n_exprs rem_input_3
        in ((DynamicDispatch n expr_type expr ident expr_list), rem_input_4)
    (line_no : expr_type : "static_dispatch" : tl) ->
        let n = read line_no :: Int
            (expr, rem_input_1) = parse_expr tl
            (ident1, rem_input_2) = parse_identifier rem_input_1
            (ident2, rem_input_3) = parse_identifier rem_input_2
            (num_exprs : rem_input_4) = rem_input_3
            n_exprs = read num_exprs :: Int
            (expr_list, rem_input_5) = parse_expr_list n_exprs rem_input_4
        in ((StaticDispatch n expr_type expr ident1 ident2 expr_list), rem_input_5)
    -- Internal
    (line_no : expr_type : "internal" : class_dot_method : tl) ->
        let n = read line_no :: Int
        in ((Internal n expr_type class_dot_method), tl)
    -- Let and Case
    (line_no : expr_type : "let" : num_bindings : tl) ->
        let n = read line_no :: Int
            nb = read num_bindings :: Int
            (bindings, rem_input) = parse_binding_list nb tl
            (expr, rem_input_2) = parse_expr rem_input
        in ( (Let n expr_type bindings expr), rem_input_2 )
    (line_no : expr_type : "case" : tl) ->
        let (expr, rem_input) = parse_expr tl
            (num_elems : rem_input_2) = rem_input
            ln = read line_no :: Int
            ne = read num_elems :: Int
            --(expr, rem_input) = parse_expr tl
            (case_elems, rem_input_3) = parse_case_elements ne rem_input_2
        in ( (Case ln expr_type expr case_elems), rem_input_3)
    _ -> error "could not match expr"

parse_case_elements 0 tl = ([], tl)
parse_case_elements n (var_ln : var_name : type_ln : type_name : tl) =
    let ln = read var_ln :: Int
        tln = read type_ln :: Int
        (expr, rem_input) = parse_expr tl
        (elems, rem_input_2) = parse_case_elements (n-1) rem_input
    in ( (CaseElement (Identifier ln var_name) (Identifier tln type_name) expr) : elems, rem_input_2)

parse_binding_list 0 tl = ([], tl)
parse_binding_list n ("let_binding_no_init" : var_ln : var_name : type_ln : type_name : tl) =
    let ln = read var_ln :: Int
        tln = read type_ln :: Int
        (binding_list, rem_input) = parse_binding_list (n-1) tl
    in ( (LetBinding (Identifier ln var_name) (Identifier tln type_name) Nothing) : binding_list, rem_input)
parse_binding_list n ("let_binding_init" : var_ln : var_name : type_ln : type_name : tl) =
    let ln = read var_ln :: Int
        tln = read type_ln :: Int
        (expr, rem_input) = parse_expr tl
        (binding_list, rem_input_2) = parse_binding_list (n-1) rem_input
    in ( (LetBinding (Identifier ln var_name) (Identifier tln type_name) (Just expr)) : binding_list, rem_input_2)

parse_expr_list 0 tl = ([], tl)
parse_expr_list n tl =
    let (expr, rem_input) = parse_expr tl
        (expr_list, rem_input_2) = parse_expr_list (n-1) rem_input
    in ( (expr : expr_list), rem_input_2)

parse_identifier (line_no : name : tl) =
    let n = read line_no :: Int
    in ((Identifier n name), tl)


------------------------------- Interpreter Functions ---------------------------------

--------- Helper Functions ---------------

-- Lookup a method in the implementation map given a class and method name
impMapLookup :: ImpMap -> String -> String -> ([String], Expr)
impMapLookup imp_map class_name f =
    let (Just (Class name feats)) = find (\(Class name _) -> name == class_name) imp_map
        (Just (Method _ formals _ expr)) = find (\(Method name _ _ _) -> name == f) feats
        in
        (formals, expr)

-- Extract a class our of the class map
getClass :: ClassMap -> String -> Class
getClass class_map name =
    let (Just clas) = find (\(Class cname _) -> cname == name) class_map in
    clas

-- Get new integer for the location in the store
newloc :: Store -> Int
newloc store =
    Map.size store

-- Given a variable name find its location in the store
envLookup :: Environment -> String -> Maybe Int
envLookup env name =
    Map.lookup name env

-- Given a location find the value in the store
storeLookup :: Store -> Int -> Maybe Value
storeLookup store loc =
    Map.lookup loc store

-- Assign the default value for the given type
default_value :: String -> Value
default_value typ = case typ of
    "Int" -> CoolInt 0
    "String" -> CoolString 0 ""
    "Bool" -> CoolBool False
    _     -> Void

-- Helper to create the new environment in dispatch expressions
createEnv :: Int -> Value -> [(String, Int)] -> Environment
createEnv line_no (Object _ obj_map) formal_locs =
    let formal_map = Map.fromList formal_locs
        env2 = Map.union formal_map obj_map in env2
createEnv line_no _ formal_locs = Map.fromList formal_locs

-- Helper function to extract the type of a value
checkForVoidAndReturnType :: Int -> Value -> String
checkForVoidAndReturnType line_no Void = error ("ERROR: " ++ (show line_no) ++ ": Exception: dispatch on void")
checkForVoidAndReturnType line_no (Object typ _) = typ
checkForVoidAndReturnType line_no (CoolString _ _) = "String"
checkForVoidAndReturnType line_no (CoolInt _) = "Int"
checkForVoidAndReturnType line_no (CoolBool _) = "Bool"

-- Check for void for dispatch and case expressions on void
checkForVoid :: Value -> Int -> StateWithIO ProgramState Value
checkForVoid Void line_no = do
        lift $ putStrLn $ "ERROR: " ++ (show line_no) ++ ": Exception: Case or Dispatch on void."
        lift $ exitSuccess
checkForVoid s _ = return s


------------- Evaluation ----------------
-- Reasonably straight forward. The state of the program is carried throughout this function via the StateTransformer.
-- These rules follows those presented in the operational semantics as precisely as possible and evaluate every cool expression.
eval :: (ClassMap, ImpMap, ParentMap, Int) -> Value -> Environment -> Expr -> StateWithIO ProgramState Value
eval (cm, im, pm, counter) so env expr =
    let eval' = eval (cm, im, pm, counter)
        checkOverflow :: Int -> Int -> StateWithIO ProgramState Value
        checkOverflow line_no counter =
            if counter + 1 >= 1000 then do
                lift $ putStrLn $ "ERROR: " ++ (show line_no) ++ ": Exception: Stack Overflow"
                lift $ exitSuccess
            else do
                return Void
        threadExprs :: Value -> Environment -> [Expr] -> StateWithIO ProgramState [Value]
        threadExprs so env [] = return []
        threadExprs so env (expr : tl) = do
            vi <- eval' so env expr
            vals <- threadExprs so env tl
            return ( vi : vals )
    in do
        case expr of
            (TrueBool _ _) ->
                return (CoolBool True)
            (FalseBool _ _) ->
                return (CoolBool False)
            (Integer _ typ int_val) ->
                return (CoolInt (fromIntegral int_val :: Int32))
            (Str _ typ str) ->
                return (CoolString (length str) str)
            (Plus line_no typ e1 e2) -> do
                CoolInt i1 <- eval' so env e1
                CoolInt i2 <- eval' so env e2
                return (CoolInt (i1 + i2))
            (Minus line_no typ e1 e2) -> do
                CoolInt i1 <- eval' so env e1
                CoolInt i2 <- eval' so env e2
                return (CoolInt (i1 - i2))
            (Times line_no typ e1 e2) -> do
                CoolInt i1 <- eval' so env e1
                CoolInt i2 <- eval' so env e2
                return (CoolInt (i1 * i2))
            (Divide line_no typ e1 e2) -> do
                CoolInt i1 <- eval' so env e1
                CoolInt i2 <- eval' so env e2
                if i2 == 0 then do
                    lift $ putStrLn $ "ERROR: " ++ (show line_no) ++ ": Exception: Division by Zero"
                    lift $ exitSuccess
                else do
                    return (CoolInt (i1 `quot` i2))
            (Equal line_no typ e1 e2) -> do
                v1 <- eval' so env e1
                v2 <- eval' so env e2
                case (v1, v2) of
                    (CoolInt i1, CoolInt i2) ->
                        let tf = i1 == i2 in do
                            return (CoolBool tf)
                    (CoolString l1 s1, CoolString l2 s2) ->
                        let tf = s1 == s2 in do
                            return (CoolBool tf)
                    (CoolBool b1, CoolBool b2) ->
                        return (CoolBool (b1 == b2))
                    (Object t1 om1, Object t2 om2) -> do
                        return (CoolBool (om1 == om2))
                    (Void, Void) ->
                        return (CoolBool True)
                    _ -> return (CoolBool False)
            (LessThan line_no typ e1 e2) -> do
                v1 <- eval' so env e1
                v2 <- eval' so env e2
                case (v1, v2) of
                    (CoolInt i1, CoolInt i2) ->
                        let tf = i1 < i2 in do
                            return (CoolBool tf)
                    (CoolString _ s1, CoolString _ s2) ->
                        return (CoolBool (s1 < s2))
                    (CoolBool b1, CoolBool b2) ->
                        return (CoolBool (b1 < b2))
                    _ -> return (CoolBool False)
            (LessEqual line_no typ e1 e2) -> do
                v1 <- eval' so env e1
                v2 <- eval' so env e2
                case (v1, v2) of
                    (CoolInt i1, CoolInt i2) ->
                        let tf = i1 <= i2 in do
                            return (CoolBool tf)
                    (CoolString _ s1, CoolString _ s2) ->
                        return (CoolBool (s1 <= s2))
                    (CoolBool b1, CoolBool b2) ->
                        return (CoolBool (b1 <= b2))
                    (Object t1 om1, Object t2 om2) ->
                        case om1 == om2 of
                            True -> return (CoolBool True)
                            False -> return (CoolBool False)
                    (Void, Void) ->
                        return (CoolBool True)
                    _ -> return (CoolBool False)
            (Negate line_no typ e1) -> do
                v1 <- eval' so env e1
                case v1 of
                    (CoolInt i) -> do
                        return (CoolInt (-i))
                    _ -> error "Calling negate on non int"
            (Not line_no typ e1) -> do
                v1 <- eval' so env e1
                case v1 of
                    (CoolBool b) -> do
                        return (CoolBool (not b))
                    _ -> error "Calling not on non bool"
            (IsVoid line_no typ e1) -> do
                v1 <- eval' so env e1
                case v1 of
                    Void -> do
                        return (CoolBool True)
                    _ -> do
                        return (CoolBool False)
            (Assign _ typ (Identifier _ name) expr) -> do
                v1 <- eval' so env expr
                store <- get
                let (Just loc) = Map.lookup name env in do
                    put (Map.insert loc v1 store)
                    return v1
            (IdentExpr _ typ (Identifier _ name)) -> case name of
                "self" -> return so
                name -> do
                    store <- get
                    let l = case (envLookup env name) of
                            Just loc -> loc
                            Nothing  -> error "Should not be looking up non-existent variable in IdentExpr"
                        val = case (storeLookup store l) of
                            Just v -> v
                            Nothing -> error "Variables should always have a value in IdentExpr" in do
                    return val
            (New line_no typ _) -> do
                store <- get
                noworries <- checkOverflow line_no counter
                let t0 = case typ of
                            "SELF_TYPE" -> let (Object x _) = so in x
                            t -> t
                    (Class name feat_list) = getClass cm t0
                    orig_l = newloc store
                    ls = [orig_l .. (orig_l + (length feat_list) )]
                    vars = [var | (Attribute var _ _) <- feat_list]
                    assoc_l = zip (typ : vars) ls
                    -- assoc_t holds assoc list from var -> type name
                    assoc_t = zip [var | (Attribute var _ _) <- feat_list] [typ | (Attribute _ typ _) <- feat_list]
                    v1 = Object t0 (Map.fromList assoc_l)
                    -- Update the store
                    lookup_type var = case (List.lookup var assoc_t) of
                        Just s -> s
                        Nothing -> error "We should not be looking up the type of a non existent variable"
                    store2 = foldl (\a (var, li) -> Map.insert li (default_value (lookup_type var)) a) store assoc_l
                    -- We now need to initialize the attributes with their respective expr
                    ----------- SETUP -------------
                    -- our goal is a set of expressions that modify attrs in scope
                    init_feat_list = filter (\(Attribute _ _ e) -> case e of
                                                        (Just e) -> True
                                                        Nothing -> False
                                            ) feat_list
                    iD ln name = Identifier ln name
                    assign_exprs = [Assign 0 t (iD 0 name) e | (Attribute name t (Just e)) <- init_feat_list]
                    env' = Map.fromList assoc_l
                    eval' = eval (cm, im, pm, counter + 1)
                    threadStore :: Value -> Environment -> Expr -> StateWithIO ProgramState Value
                    threadStore so env e = do
                        eval' so env e
                    threadStore' = threadStore v1 env'
                    in do
                        put store2
                        vs <- mapM (threadStore') assign_exprs
                        s <- get
                        let Just val = storeLookup s 1 in do
                            return v1
            (DynamicDispatch line_no typ e0 (Identifier _ f) exprs) -> do
                vals <- threadExprs so env exprs
                v0 <- eval' so env e0
                store <- get
                noworries <- checkOverflow line_no counter
                unused <- checkForVoid v0 line_no
                let v0_typ = checkForVoidAndReturnType line_no v0
                    (formals, e_n1) = impMapLookup im v0_typ f
                    orig_l = newloc store
                    ls = [orig_l .. (orig_l + (length formals) -1)]
                    assoc_l = zip vals ls
                    store_n3 = foldl (\a (val, li) -> Map.insert li val a) store assoc_l
                    form_ls = zip formals ls
                    eval' = eval (cm, im, pm, counter + 1)
                    env2 = createEnv line_no v0 form_ls in do
                        put store_n3
                        v_n1 <- eval' v0 env2 e_n1
                        return v_n1
            (SelfDispatch line_no typ (Identifier _ f) exprs) -> do
                vals <- threadExprs so env exprs
                store <- get
                noworries <- checkOverflow line_no counter
                unused <- checkForVoid so line_no
                let so_typ = checkForVoidAndReturnType line_no so
                    (formals, e_n1) = impMapLookup im so_typ f
                    orig_l = newloc store
                    ls = [orig_l .. (orig_l + (length formals) -1)]
                    assoc_l = zip vals ls
                    store_n3 = foldl (\a (val, li) -> Map.insert li val a) store assoc_l
                    form_ls = zip formals ls
                    eval' = eval (cm, im, pm, counter + 1)
                    env2 = createEnv line_no so form_ls in do
                        put store_n3
                        v_n1 <- eval' so env2 e_n1
                        return v_n1
            (StaticDispatch line_no typ e0 (Identifier _ name) (Identifier _ f) exprs) -> do
                vals <- threadExprs so env exprs
                v0 <- eval' so env e0
                store <- get
                noworries <- checkOverflow line_no counter
                unused <- checkForVoid v0 line_no
                let v0_typ = checkForVoidAndReturnType line_no v0
                    (formals, e_n1) = impMapLookup im name f
                    orig_l = newloc store
                    ls = [orig_l .. (orig_l + (length formals) -1)]
                    assoc_l = zip vals ls
                    store_n3 = foldl (\a (val, li) -> Map.insert li val a) store assoc_l
                    form_ls = zip formals ls
                    eval' = eval (cm, im, pm, counter + 1)
                    env2 = createEnv line_no v0 form_ls in do
                        put store_n3
                        v_n1 <- eval' v0 env2 e_n1
                        return v_n1
            (If line_no typ e1 e2 e3) -> do
                v1 <- eval' so env e1
                case v1 of
                    (CoolBool True) -> do
                        v2 <- eval' so env e2
                        return v2
                    (CoolBool False) -> do
                        v3 <- eval' so env e3
                        return v3
            (Block line_no typ exprs) -> do
                vals <- threadExprs so env exprs
                return (last vals)
            (While line_no typ e1 e2) -> do
                v1 <- eval' so env e1
                case v1 of
                    (CoolBool True) -> do
                        v2 <- eval' so env e2
                        eval' so env (While line_no typ e1 e2)
                        return Void
                    (CoolBool False) -> do
                        return Void
            (Case line_no typ e0 elems) -> do
                v0 <- eval' so env e0
                unused <- checkForVoid v0 line_no
                let types = foldl (\a (CaseElement _ (Identifier _ typ) _) -> typ : a) [] elems
                    closest_ans :: ParentMap -> String -> [String] -> Maybe String
                    closest_ans pmap typ typs =
                        let parent = case (lookup typ pmap) of
                                Just p -> Just p
                                Nothing -> Nothing
                            in
                                case (typ `elem` typs) of
                                    True -> Just typ
                                    False -> case parent of
                                        Just p -> closest_ans pmap p typs
                                        Nothing -> Nothing
                    ti = closest_ans pm (checkForVoidAndReturnType line_no v0) types
                    in do
                        case ti of
                            Just ti ->
                                let (idi, ei) = case (find (\(CaseElement _ (Identifier _ typ) _) -> typ == ti) elems) of
                                        Just (CaseElement (Identifier _ name) _ expr) -> (name, expr)
                                        Nothing -> error "This should never happen in Case"
                                in do
                                    s2 <- get
                                    let l0 = newloc s2
                                        s3 = Map.insert l0 v0 s2 in do
                                            put s3
                                            v1 <- eval' so (Map.insert idi l0 env) ei
                                            return v1
                            Nothing -> do
                                lift $ putStrLn $ "ERROR: " ++ (show line_no) ++ ": Exception: case without matching branch"
                                lift $ exitSuccess
                                return Void
            (Let line_no typ [] e2) -> do
                s <- get
                eval' so env e2
            (Let line_no typ ((LetBinding (Identifier _ name) (Identifier _ t1) e1) : rem_binds) e2) -> do
                case e1 of
                    Just expr -> do
                        v1 <- eval' so env expr
                        s2 <- get
                        let l1 = newloc s2
                            s3 = Map.insert l1 v1 s2
                            env2 = Map.insert name l1 env
                            in do
                                put s3
                                eval' so env2 (Let line_no typ rem_binds e2)
                    Nothing -> do
                        s2 <- get
                        let v1 = default_value t1
                            l1 = newloc s2
                            s3 = Map.insert l1 v1 s2
                            env2 = Map.insert name l1 env
                            in do
                                put s3
                                eval' so env2 (Let line_no typ rem_binds e2)
            (Internal line_no typ name) -> do
                case name of
                    "IO.out_string" -> do
                        s <- get
                        let (Just l) = Map.lookup "x" env
                            (Just (CoolString len str)) = Map.lookup l s
                            s' = '"' : str ++ "\""
                            in do
                                out_string so env (read s')
                    "IO.out_int" -> do
                        s <- get
                        let (Just l) = Map.lookup "x" env
                            (Just (CoolInt i)) = Map.lookup l s
                            in do
                                out_int so env (fromIntegral i :: Int)
                    "IO.in_string" -> do
                        in_string so env
                    "IO.in_int" -> do
                        in_int so env
                    "Object.abort" -> do
                        abort so env
                        return Void
                    "Object.type_name" -> do
                        type_name so env
                    "Object.copy" -> do
                        copy so env
                    "String.concat" -> do
                        store <- get
                        let (Just l) = Map.lookup "s" env
                            (Just (CoolString len s)) = Map.lookup l store
                            in do
                                concool so env s
                    "String.length" -> do
                        cool_len so env
                    "String.substr" -> do
                        store <- get
                        let (Just l) = Map.lookup "i" env
                            (Just (CoolInt i)) = Map.lookup l store
                            (Just l2) = Map.lookup "l" env
                            (Just (CoolInt len)) = Map.lookup l2 store
                            in do
                                cool_substr so env (fromIntegral i :: Int) (fromIntegral len :: Int)

-- The below methods handle the runtime environment that cool supplies to the programmers.
-- These calls deal with IO, copying, aborting, and string manipulation
out_string :: Value -> Environment -> String -> StateWithIO ProgramState Value
out_string so env str = do
    -- The lift function allows you to be able to use the IO monad embedded in the state monad
    lift $ putStr str
    lift $ hFlush stdout
    return so

out_int :: Value -> Environment -> Int -> StateWithIO ProgramState Value
out_int so env int = do
    lift $ putStr $ show int
    return so

in_string :: Value -> Environment -> StateWithIO ProgramState Value
in_string so env = do
    either_i <- lift $ (try getLine :: IO (Either SomeException String))
    let n_input = case either_i of
            (Left someExcept) -> ""
            (Right str)       -> str
        input = if elem '\NUL' n_input then ""
                else n_input
    return (CoolString (length input) input)

in_int :: Value -> Environment -> StateWithIO ProgramState Value
in_int so env = do
    either_i <- lift $ (try getLine :: IO (Either SomeException String))
    let input = case either_i of
            (Left someExcept) -> "0"
            (Right str)       -> str
        int = case reads input :: [(Integer, String)] of
            [(n, _)] -> n
            _ -> 0 in
            if int > 2147483647 || int < -2147483648 then do
                return (CoolInt 0)
            else do
                return (CoolInt (fromIntegral int :: Int32))

abort :: Value -> Environment -> StateWithIO ProgramState Value
abort so env = do
    lift $ putStrLn "abort"
    lift $ exitSuccess

type_name :: Value -> Environment -> StateWithIO ProgramState Value
type_name so env = case so of
    CoolBool b -> return (CoolString 4 "Bool")
    CoolInt i -> return (CoolString 3 "Int")
    CoolString len s -> return (CoolString 5 "String")
    Object typ _ -> return (CoolString (length typ) typ)

extractVals :: Store -> [(Name, Int)] -> [Value]
extractVals store [] = []
extractVals store ( (var, loc) : tl) =
    let new_vals = extractVals store tl
        -- Get the old value held in the store
        (Just val) = Map.lookup loc store
        in
            (val : new_vals)

copy :: Value -> Environment -> StateWithIO ProgramState Value
copy so env = do
    store <- get
    case so of
        Object typ om ->
            let orig_l = newloc store
                new_locs = [orig_l .. (orig_l + (Map.size om))]
                old_key_locs = Map.assocs om
                names = [ name | (name, _) <- old_key_locs]
                vals = extractVals store old_key_locs
                -- has type (new_loc, value)
                new_loc_vals = zip new_locs vals
                -- Populate the store with our new copied data
                store2 = foldl (\a (loc, val) -> Map.insert loc val a) store new_loc_vals
                -- Create the new objMap with the new locs and names
                new_name_locs = zip names new_locs
                new_om = Map.fromList new_name_locs in do
                    put store2
                    return (Object typ new_om)
        other -> return other

cool_len :: Value -> Environment -> StateWithIO ProgramState Value
cool_len (CoolString len s) env = return (CoolInt (fromIntegral len :: Int32))

concool :: Value -> Environment -> String -> StateWithIO ProgramState Value
concool (CoolString len s1) env s2 = let new_str = s1 ++ s2 in
    return (CoolString (length new_str) new_str)

cool_substr :: Value -> Environment -> Int -> Int -> StateWithIO ProgramState Value
cool_substr (CoolString len s) env i l
    | (i <= len && i >= 0) && ( (i + l) <= len && l >= 0) = let substr = take l . drop i $ s in
        return (CoolString (length substr) substr)
    | otherwise = do
        lift $ putStrLn "ERROR: 0: Exception: String.substr out of range"
        lift $ exitSuccess


-- Main Execution.. Parse cl-type file and run (new Main).main()
main = do
    args <- getArgs
    if length args == 0 then
        error "Please supply the .cl-type file as the command line argument"
    else do
        contents <- readFile (args !! 0)
        let class_map = parse_cm $ lines contents
            imp_map = parse_imp_map $ lines contents
            (parent_map, ast) = parse_parent_map_and_ast $ lines contents
            _null = Object "NULL" Map.empty
            newM = New 0 "Main" (Identifier 0 "")
            mainMeth = DynamicDispatch 0 "Object" newM (Identifier 0 "main") []
            curried = (class_map, imp_map, parent_map)
            init_state = Map.empty :: Map Location Value
            in do
                ret <- (evalStateT (eval (class_map, imp_map, parent_map, 0) _null Map.empty mainMeth) init_state)
                return ()
