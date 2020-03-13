{- |
 * Three address code
 *
 * Copyright : (c) 
 *  Francisco Javier    12-11163
 *  Natascha Gamboa     12-11250
-}
module Playit.BackEnd.TAC (tacInitState, gen) where

import Control.Monad.IO.Class      (liftIO)
import Control.Monad               (when, unless)
import Control.Monad.Trans.RWS     (ask, tell, get, put)
import Data.Maybe                  (fromJust, isNothing)
import Playit.BackEnd.Utils    
import Playit.BackEnd.Types
import Playit.FrontEnd.SymbolTable (lookupInSymTab)
import Playit.FrontEnd.Types
import Playit.FrontEnd.Utils       (typeVar, baseTypeT, isArrLst, baseTypeE, typeE)
import qualified Data.Map          as M
import qualified TACType           as T


-- Colocar los temps de print, read y null al inicio?
tacInitState :: SymTab -> Operands
tacInitState = Operands M.empty temps M.empty [] brk cont 0 False False []
  where
    retnReg  = Temp "_return" (-1)  -- $v0, offset fijo?
    nullReg  = Temp "_null" (-1)    -- $zero, offset fijo?
    printReg = Temp "_print" (-1)   -- syscall 4
    readReg  = Temp "_read" (-1)    -- syscall 8
    cont     = tacLabel "cont"
    brk      = tacLabel "brk"
    temps    = M.fromList [(retnReg, False), (nullReg, False), (printReg, False), (readReg, False)]


gen :: Instr -> TACMonad ()
gen ast = tell (tacCall Nothing "_main" 0 ++ tacNewLabel (tacLabel "_main")) >>
          genCode ast

-- 
genCode :: Instr -> TACMonad ()
genCode i = case i of
  (Program is _)             -> mapM_ genCode is >> genSubroutines
  (Assigs is _)              -> mapM_ genCode is
  (Assig v e _)              -> newLabel >>= genAssig v e
  (Break _)                  -> genBreak
  (Continue _)               -> genContinue
  (For n e1 e2 is _)         -> breakI   >>= genFor n e1 e2 is
  (ForEach n e is _)         -> breakI   >>= genForEach n e is
  (ForWhile n e1 e2 e3 is _) -> breakI   >>= genForWhile n e1 e2 e3 is
  (IF gs _)                  -> newLabel >>= genIF gs
  (While e is _)             -> breakI   >>= genWhile e is
  (Print es _)               -> genPrint es
  (Free id _)                -> genFree id
  (ProcCall s _)             -> genProcCall s
  (Return e _)               -> genExpr e >>= genReturn


genSubroutines :: TACMonad ()
genSubroutines = do
  state <- get
  mapM_ genSubroutine (subs state)
  when (callM state) (resetOffset >> malloc)
  when (callF state) (resetOffset >> free)


genSubroutine :: (Id, InstrSeq, Bool) -> TACMonad ()
genSubroutine (s, i, isProc) =
  resetOffset >> tell (tacNewLabel $ tacLabel s) >> mapM_ genCode i >> 
    when isProc (genReturn Nothing)
-------------------------------------------------------------------------------
-------------------------------------------------------------------------------
--                            TAC Instructions
-------------------------------------------------------------------------------
-------------------------------------------------------------------------------


-- Registros/Uniones
genAssig :: Var -> Expr -> TACOP -> TACMonad ()
genAssig var e nextL = case typeVar var of
  -- Si es el operador ternario la expr puede ser bool o no
  TBool -> do
    vTemp  <- genVar var (typeVar var)
    trueL  <- newLabel
    falseL <- newLabel
    genBoolExpr e trueL falseL
    tell (tacNewLabel trueL)
    tell (tacAssign vTemp $ tacConstant ("True", TBool))
    tell (tacGoto nextL)
    tell (tacNewLabel falseL)
    tell (tacAssign vTemp $ tacConstant ("False", TBool))
    tell (tacNewLabel nextL)
-- Registros y uniones
  TNew n -> do
    e<-genExpr e
    return ()
--
  _ -> do
    eTemp <- genExpr e
    vTemp <- genVar var (typeVar var)
    {- 
      if isField var then
      else
        base/fp[var.offset] := e
    -}
    unless (isArrLst e) $ tell $ tacAssign vTemp eTemp


-- 
genFor :: Id -> Expr -> Expr -> InstrSeq -> TACOP -> TACMonad ()
genFor n e1 e2 is nextL = forComparison n e1 e2 nextL >>= forInstrs is nextL


-- 
genForEach :: Id -> Expr -> InstrSeq -> TACOP -> TACMonad ()
genForEach n e is nextL = do
  let
    t = baseTypeE e
    w = getWidth t
  begin <- newLabel
  contn <- continue
  var   <- genVar (Var n t) t
  expr  <- genExpr e
  count <- genVar (Var ("$i_" ++ n) t) TInt
  tell (tacUn T.Deref count expr)
  tell (tacNewLabel begin)
  tell (tacBin T.Lte count (tacConstant ("0", TInt)) nextL)
  iterVarShft <- genBinOp Add TInt expr (tacConstant (show w, TInt))
  tell (tacUn T.Deref var iterVarShft)
  mapM_ genCode is
  tell (tacNewLabel contn)
  countIncrmt <- genBinOp Minus TInt count (tacConstant ("1", TInt))
  tell (tacAssign count countIncrmt)
  tell (tacGoto begin)
  tell (tacNewLabel nextL)

-- 
genForWhile :: Id -> Expr -> Expr -> Expr -> InstrSeq -> TACOP -> TACMonad ()
genForWhile n e1 e2 cond is nextL = do
  iteration <- forComparison n e1 e2 nextL
  genBoolExpr cond fall nextL
  forInstrs is nextL iteration


-- 
genIF :: [(Expr, InstrSeq)] -> TACOP -> TACMonad ()
genIF [] nextL               = tell (tacNewLabel nextL)
genIF ((e, is):guards) nextL = do
  let isLast = null guards
  falseL <- if isLast then return nextL else newLabel
  genBoolExpr e fall falseL
  mapM_ genCode is
  unless isLast $ tell (tacGoto nextL)
  unless isLast $ tell (tacNewLabel falseL)
  when isLast $ return ()
  genIF guards nextL


-- 
genWhile :: Expr -> InstrSeq -> TACOP -> TACMonad ()
genWhile e is nextL = do
  begin <- continue
  tell (tacNewLabel begin)
  genBoolExpr e fall nextL
  mapM_ genCode is
  tell (tacGoto begin)
  tell (tacNewLabel nextL)


-- syscall 4
-- TODO: width del tipo string
genPrint :: [Expr] -> TACMonad ()
genPrint es = do
  lv     <- pushOffset (getWidth (typeE (head es))) >>= newTemp
  params <- mapM genExpr es
  syscall 8 lv params


-- Aqui se llama a free, Prologo
genFree :: Id -> TACMonad ()
genFree varId = do
  state@Operands{vars = vs, astST = st} <- get
  let -- Si se cambia por 'free Expr' no tendria que buscar en la symtab
    varT = symType . head . fromJust $ lookupInSymTab varId st
    var  = fromJust $ M.lookup (Var varId varT) vs
  tell [tacParam var]
  tell (tacCall Nothing "free" 1)
  -- prólogo
  put state{callF = True}


-------------------------------------------------------------------------------
-- Hace prologo
genProcCall :: Subroutine -> TACMonad ()
genProcCall (Call s params) = do
  pushSubroutine s True
  genParams (map fst params)
  -- Prologo antes de pasar el poder al proc
  tell (tacCall Nothing s $ length params)

-- 
genParams :: [Expr] -> TACMonad ()
genParams params = do
  operands <- mapM genExpr params
  tell $ map tacParam operands
-------------------------------------------------------------------------------


-- Hace epilogo
genReturn :: TACOP -> TACMonad ()
genReturn e = tell [T.ThreeAddressCode T.Return Nothing e Nothing]


-- 
genContinue :: TACMonad ()
genContinue = do
  Operands{contL = continue} <- get
  tell (tacGoto continue)


-- 
genBreak :: TACMonad ()
genBreak = do
  Operands{brkL = break} <- get
  tell (tacGoto break)


-------------------------------------------------------------------------------
-------------------------------------------------------------------------------
--                             TAC Expressions
-------------------------------------------------------------------------------
-------------------------------------------------------------------------------


genExpr :: Expr -> TACMonad TACOP
genExpr e = case e of
  Literal l t         -> genLiteral l t
  Variable v t        -> genVar v t
  Unary u e t         -> genUnOp u e t
  Binary b e1 e2 t    -> do
    e1Temp <- genExpr e1
    e2Temp <- genExpr e2
    genBinOp b t e1Temp e2Temp
  IfSimple eB eT eF t -> genTerOp eB eT eF t
  ArrayList es t      ->
    let width = getWidth (baseTypeT t)
    in pushOffset width >>= newTemp >>= genArrayList es width 0
  Null                -> genNull
  Read e _            -> genRead e
  FuncCall s _        -> genFuncCall s
  IdType t            -> genType t


-- Array de bools, apuntador a bool
genBoolExpr :: Expr -> TACOP -> TACOP -> TACMonad ()
genBoolExpr e trueL falseL =  
  case e of
    Literal (Boolean True) _  -> unless (isFall trueL) $ tell (tacGoto trueL)
    Literal (Boolean False) _ -> unless (isFall falseL) $ tell (tacGoto falseL)
    Unary Not e _             -> genBoolExpr e falseL trueL
  -- Variables
  -- Comparators
    Binary op e1 e2 _ | op `elem` [Greater, GreaterEq, Less, LessEq, Eq, NotEq] -> do
      leftExpr  <- genExpr e1
      rightExpr <- genExpr e2
      genComparison leftExpr rightExpr trueL falseL op
  -- Conjunction and disjunction
    Binary op e1 e2 _ | op `elem` [And, Or] -> do
      e1TrueL <- -- for `or` we need to generate a new `true` label if the current is `fall`
        if op == Or then if isFall trueL then newLabel else return trueL
        else return fall
      e1FalseL <-
        if op == And then if isFall falseL then newLabel else return falseL
        else return fall
      
      genBoolExpr e1 e1TrueL e1FalseL
      genBoolExpr e2 trueL falseL
      if op == And then
        when (isFall falseL) $ tell (tacNewLabel e1FalseL)
      else
        when (isFall trueL) $ tell (tacNewLabel e1TrueL)
  -- Functions
  -- Ternary operator
  -- 
    e -> error $ "Unexpected boolean expression:  " ++ show e


genComparison :: TACOP -> TACOP -> TACOP -> TACOP -> BinOp -> TACMonad ()
genComparison leftExpr rightExpr trueL falseL op = do
    let
      trueNotFall  = not $ isFall trueL
      falseNotFall = not $ isFall falseL
    
    if trueNotFall && falseNotFall then
      tell (tacBin (binOpToTACOP op) leftExpr rightExpr trueL) >> tell (tacGoto falseL)
    else
      if trueNotFall then tell (tacBin (binOpToTACOP op) leftExpr rightExpr trueL)
      else
        when falseNotFall $
          tell (tacBin (negation $ binOpToTACOP op) leftExpr rightExpr falseL)


-- 
genNull :: TACMonad TACOP
genNull = return $ tacVariable $ Temp "_null" (-1)


-- | Generates the TAC code for literals
{- TODO:
  EmptyVal -> Usado cuando no se coloca msj en el read
  Register
  Union
  ArrLst -> Realmente se llega hasta aqui?
  String
-}
genLiteral :: Literal -> Type -> TACMonad TACOP
genLiteral l typeL = -- do
  -- actO <- pushOffset (getWidth typeL)
  -- lv   <- newTemp actO
  -- pushLiteral l lv
  -- let
  
  -- case l of
    {-
      ArrLst elems -> -- No llega aqui
        liftIO (print ("Llegue a literal ArrLst: " ++ show elems)) >> return (tacLabel "lit arrLst")
      Str s -> do
    -}
    -- EmptyVal -> return ([T.ThreeAddressCode T.Assign lv rv Nothing], lv)
    -- (Register es) -> return ([T.ThreeAddressCode T.Assign lv rv Nothing], lv)
    -- _ ->
  return $ tacConstant (show l, typeL)


-- 
{- TODO:
  casos bloques anidados que acceden a los ids
  Param Id Type Ref
  Field Var Id Type
  Index
-}
genVar :: Var -> Type -> TACMonad TACOP
genVar var tVar =
  case var of
    Param _ _ Reference -> do -- error "Un parametro no deberia poder estar en una asignacion"
      actO   <- pushOffset (getWidth tVar)
      lv     <- newTemp actO
      tacVar <- pushVariable var tVar
      tell (tacUn T.Deref lv tacVar) >> return lv
    Desref _ t -> do
      actO   <- pushOffset (getWidth tVar)
      lv     <- newTemp actO
      tacVar <- pushVariable (getRefVar var) tVar
      tell (tacUn T.Deref lv tacVar) >> return lv
    -- Field v f t -> return()
    -- Index v e t -> return()
    _     -> pushVariable var tVar


-- Prolog con New
genUnOp :: UnOp -> Expr -> Type -> TACMonad TACOP
genUnOp op e tOp = do
  rv   <- genExpr e
  actO <- pushOffset (getWidth tOp)
  lv   <- newTemp actO
  
  case op of
    Length   -> tell (tacUn T.Length lv rv) >> return lv
    Negative -> tell (tacUn T.Minus lv rv)  >> return lv
    New      -> do
      tell [tacParam rv]
      tell (tacCall lv "malloc" 1)
      -- prólogo
      state <- get
      put state{callM = True}
      return lv
    charOp   -> do
      l0 <- newLabel
      l1 <- newLabel
      l2 <- newLabel
      let
        c0    = tacConstant ("0", TInt)
        c25   = tacConstant ("25", TInt)
        c32   = tacConstant ("32", TInt)
        check = tacBin T.Gte lv c0 l0 ++ tacGoto l2 ++ tacNewLabel l0 ++ tacBin T.Sub lv rv c25
        goNew = tacGoto l2 ++ tacNewLabel l1

      if charOp == UpperCase then do
        tell (tacBin T.Sub lv rv $ tacConstant ("97", TInt))
        tell check
        tell (tacBin T.Gte lv c0 l0)
        tell goNew
        tell (tacBin T.Sub lv rv c32)
        tell (tacNewLabel l2)
        return lv
      else do
        tell (tacBin T.Sub lv rv $ tacConstant ("65", TInt))
        tell check
        tell (tacBin T.Lte lv c0 l0)
        tell goNew
        tell (tacBin T.Add lv rv c32)
        tell (tacNewLabel l2)
        return lv


-- TODO: Listas
genBinOp :: BinOp -> Type -> TACOP -> TACOP -> TACMonad TACOP
genBinOp op tOp rv1 rv2 = do
  actO <- pushOffset (getWidth tOp)
  lv   <- newTemp actO
  
  -- case op of
  -- Aritmethics
  --  op ->
  tell (tacBin (binOpToTACOP op) lv rv1 rv2)  >> return lv
  -- Lists
    -- Anexo  -> return (e1Code ++ e2Code ++ [T.ThreeAddressCode T.Anexo lvt e1Temp e2Temp], lvt)
    -- Concat -> return (e1Code ++ e2Code ++ [T.ThreeAddressCode T.Concat lvt e1Temp e2Temp], lvt)


-- 
genTerOp :: Expr -> Expr -> Expr -> Type -> TACMonad TACOP
genTerOp eB eT eF tOp = do
  actO   <- pushOffset (getWidth tOp)
  lv     <- newTemp actO
  next   <- newLabel
  falseL <- newLabel
  genBoolExpr eB fall falseL
  eTTemp <- genExpr eT
  tell (tacAssign lv eTTemp)
  tell (tacGoto next)
  tell (tacNewLabel falseL)
  eFTemp <- genExpr eF
  tell (tacAssign lv eFTemp)
  tell (tacNewLabel next)
  return lv


-- 
genArrayList :: [Expr] -> Int -> Int -> TACOP -> TACMonad TACOP
genArrayList [] _ index arrTemp               =
  let len = tacConstant (show index, TInt)
  in tell (tacSet arrTemp (tacConstant ("0", TInt)) len) >> return arrTemp
genArrayList (elem:elems) width index arrTemp = do
  elemTemp <- genExpr elem
  tell (tacSet arrTemp (tacConstant (show (index + 1), TInt)) elemTemp)
  actO     <- pushOffset width
  genArrayList elems width (index + 1) (modifyOffSet arrTemp actO)


-- syscall 8
-- TODO: width del tipo string
genRead :: Expr -> TACMonad TACOP
genRead e = do
  lv    <- pushOffset (getWidth (typeE e)) >>= newTemp
  param <- genExpr e
  syscall 8 lv [param]
  return lv


-- Hace prologo
genFuncCall :: Subroutine -> TACMonad TACOP
genFuncCall (Call f params) = do
  pushSubroutine f False
  genParams (map fst params)
  Operands{base = actO} <- get
  lv <- newTemp actO -- Deberia ser el offset del tipo de retorno de la funcion, como lo obtengo?
  -- Prologo antes de pasar el poder al proc
  tell (tacCall lv f $ length params)
  return lv


-- Retorna el tamaño a ser reservado en memoria
genType :: Type -> TACMonad TACOP
genType t = return (tacConstant (show (getWidth t),TInt))


-------------------------------------------------------------------------------
-------------------------------------------------------------------------------
--- Auxiliares que deben ir en este archivo


forComparison :: Id -> Expr -> Expr -> TACOP -> TACMonad (TACOP, TACOP, TACOP)
forComparison n e1 e2 nextL = do
  begin   <- newLabel
  cont    <- continue
  iterVar <- genExpr (Variable (Var n TInt) TInt)
  e1Temp  <- genExpr e1
  tell (tacAssign iterVar e1Temp)
  e2Temp  <- genExpr e2
  tell (tacNewLabel begin)
  genComparison iterVar e2Temp fall nextL LessEq
  return (begin, cont, iterVar)


forInstrs :: InstrSeq -> TACOP -> (TACOP, TACOP, TACOP) -> TACMonad ()
forInstrs is nextL (begin, cont, iterVar) = do
  mapM_ genCode is
  tell (tacNewLabel cont)
  iterVarIncr <- genBinOp Add TInt iterVar (tacConstant ("1", TInt))
  tell (tacAssign iterVar iterVarIncr)
  tell (tacGoto begin)
  tell (tacNewLabel nextL)
