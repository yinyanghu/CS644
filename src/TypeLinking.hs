module TypeLinking where

import Data.Maybe
import Data.List
import Environment
import TypeDatabase
import AST
import TypeChecking

typeLinkingFailure :: String -> [Type]
typeLinkingFailure msg = error msg
--typeLinkingFailure msg = []

typeLinkingCheck :: TypeNode -> [[String]] -> Environment -> [Type]
typeLinkingCheck _ _ ENVE = [TypeVoid]
typeLinkingCheck db imps (ENV su c) = if elem Nothing imps' then [] else tps
    where
        (SU cname kd st inhf) = su
        [sym] = [sym | sym <- symbolTable inhf, localName sym == last cname]
        SYM mds ls ln lt = sym
        
        imps' = map (traverseNodeEntry db) imps
        
        cts = map (\env -> typeLinkingCheck db imps env) c
        cts' = if and $ map (\tps -> tps /= []) cts then [TypeVoid] else []
        
        [varsym] = st
        tps = case kd of
                Var expr -> if typeLinkingExpr db imps su (Binary "=" (ID (Name ([localName varsym])) 0) expr 0) == [] then [] else cts'
                Exp expr -> typeLinkingExpr db imps su expr
                
                Ret expr -> if typeLinkingExpr db imps su expr == [] then [] else cts'
                WhileBlock expr -> if typeLinkingExpr db imps su expr == [] then [] else cts'
                IfBlock expr -> if typeLinkingExpr db imps su expr == [] then [] else cts'
                
                Class -> case typeLinkingPrefix db imps (scope su) of
                            _ -> cts'
                Method _ -> cts'
                _ -> cts'

typeLinkingPrefix :: TypeNode -> [[String]] -> [String] -> [[String]]
typeLinkingPrefix db imps cname = concat tps
    where
        ps = map (\i -> (take i cname)) [1..(length $ init cname)]
        tps = map (traverseTypeEntryWithImports db imps) ps


filterNonFunction (Function _ _ _) = False
filterNonFunction _ = True
---------------------------------------------------------------------------------------------------------

typeLinkingExpr :: TypeNode -> [[String]] -> SemanticUnit -> Expression -> [Type]
typeLinkingExpr db imps su Null = [TypeNull]
typeLinkingExpr db imps su (Unary op expr _) = case op of
                                                "!" -> if null $ conversion db tp TypeBoolean then typeLinkingFailure "Unary !" else [tp]
                                                "-" -> if null $ conversion db tp TypeInt then typeLinkingFailure "Unary -" else [tp]
    where
        [tp] = typeLinkingExpr db imps su expr
typeLinkingExpr db imps su expr@(Binary op exprL exprR _)
    |   elem op ["+"] = case (typeL, typeR) of
                            ((Object (Name ["java", "lang", "String"])), _) -> [(Object (Name ["java", "lang", "String"]))]
                            (_, (Object (Name ["java", "lang", "String"]))) -> [(Object (Name ["java", "lang", "String"]))]
                            (_, _) -> if typeLInt && typeRInt then typeLR else typeLinkingFailure "Binary +"
    |   elem op ["-", "*", "/", "%"] = if typeLInt && typeRInt then typeLR else typeLinkingFailure "Binary arithematic op"
    |   elem op ["<", ">", "<=", ">="] = if typeLInt && typeRInt then [TypeBoolean] else typeLinkingFailure "Binary comparision op"
    |   elem op ["&&", "||", "&", "|"] = if typeLBool && typeRBool then [TypeBoolean] else typeLinkingFailure "Binary logical op"
    |   elem op ["=="] = if null typeLR then typeLinkingFailure "Binary ==" else [TypeBoolean]
    |   elem op ["="] = if assignRL then [typeL] else typeLinkingFailure $ "Binary =" ++ (show typeL) ++ (show typeR) ++ (show $ conversion db typeR typeL)
    where
        [typeL] = case filter filterNonFunction $ typeLinkingExpr db imps su exprL of
                            [] -> typeLinkingFailure $ "Binary typeL no match: type(left) " ++ op ++ " type(right)" ++ (show exprL) ++ (show exprR)
                            [l] -> [l]
                            a -> typeLinkingFailure $ "Binary typeL multi match: type(left) " ++ op ++ " type(right)" ++ (show exprL) ++ (show exprR) ++ (show a)

        [typeR] = case filter filterNonFunction $ typeLinkingExpr db imps su exprR of
                            [] -> typeLinkingFailure $ "Binary typeR no match: type(left) " ++ op ++ " type(right)" ++ (show exprL) ++ (show exprR)
                            [r] -> [r]
                            a -> typeLinkingFailure $ "Binary typeR multi match: type(left) " ++ op ++ " type(right)" ++ (show exprL) ++ (show exprR) ++ (show a)
        assignRL = not . null $ conversion db typeR typeL
        typeLR = case (null $ conversion db typeL typeR, null $ conversion db typeR typeL) of
                    (True, True) -> []
                    (False, _) -> [typeR]
                    (_, False) -> [typeL]
        typeLInt = not . null $ conversion db typeL TypeInt
        typeRInt = not . null $ conversion db typeR TypeInt
        typeLBool= not . null $ conversion db typeL TypeBoolean
        typeRBool = not . null $ conversion db typeR TypeBoolean


typeLinkingExpr db imps su (ID nm _) = typeLinkingName db imps su nm
typeLinkingExpr db imps su This = if scopeStatic su then typeLinkingFailure "This not accessible from static scope" else [lookUpThis su]
typeLinkingExpr db imps su (Value tp _ _) = [tp]
--ToDO: check if instance of is legit
typeLinkingExpr db imps su (InstanceOf tp expr _) = if typeLinkingExpr db imps su expr == [] then typeLinkingFailure "InstanceOf illegal use" else [TypeBoolean]

typeLinkingExpr db imps su (FunctionCall exprf args _) = case fts' of
                                                            [] -> typeLinkingFailure ("func " ++ (show exprf) ++ (show fts) ++ (show args))
                                                            (Function nm pt rt):_ -> [rt]
                                                            _ -> typeLinkingFailure ("func mul" ++ (show exprf) ++ (show args))
--if and $ map (\(lt, lts) -> [lt] == lts) (zip pt ats) then [rt] else []
        where
                --fts = [Function pt rt | Function pt rt <- typeLinkingExpr db imps su exprf]
                fts = typeLinkingExpr db imps su exprf
                fts' = [Function nm pt rt | ft@(Function nm pt rt) <- fts, length pt == length args]
                ats = map (typeLinkingExpr db imps su) args

typeLinkingExpr db imps su expr@(Attribute s m _) = case typeLinkingExpr db imps su s of
                                                        [] -> []-- typeLinkingFailure ("Attr " ++ (show s) ++ (show m))
                                                        --should handle Class and instance differently
                                                        [tp] -> case traverseInstanceEntry' db db ((typeToName tp)++[m]) of
                                                                    [] -> typeLinkingFailure ("Attr " ++ (show expr) ++ (show ((typeToName tp)++[m])))
                                                                    --instance look up should not return multiple candidates
                                                                    nodes -> map (symbolToType . symbol) nodes
                                                        _ -> typeLinkingFailure ("Attr " ++ (show s) ++ (show m))

-- import rule plays here
typeLinkingExpr db imps su (NewObject tp args dp) = case [TypeClass (Name nm) | TypeClass (Name nm) <- lookUpDB db imps su (typeToName tp)] of
                                                        [] -> typeLinkingFailure $ "New Object: " ++ (show tp) ++ (show args) ++ (show imps)
                                                        (TypeClass (Name nm)):_ -> let Just tn = getTypeEntry db nm in if elem "abstract" ((symbolModifiers . symbol) tn) then [] else [Object (Name nm)]
-- to check param types

typeLinkingExpr db imps su (NewArray tp exprd _ _) = if not . null $ conversion db typeIdx TypeInt then [Array tp] else typeLinkingFailure "Array: index is not an integer"
        where
                [typeIdx] = case typeLinkingExpr db imps su exprd of
                                [tp] -> [tp]
                                tps -> typeLinkingFailure $ "Array Index multi: " ++ (show exprd) ++ (show tps)

typeLinkingExpr db imps su (Dimension _ expr _) = case typeIdx of
                                                        [tp] -> if elem tp [TypeByte, TypeShort, TypeInt, TypeChar] then [tp] else []--typeLinkingFailure "Array: index is not an integer"
                                                        _ -> typeLinkingFailure "Array Index Type typeLinkingFailure"
        where
                typeIdx = typeLinkingExpr db imps su expr

typeLinkingExpr db imps su (ArrayAccess arr idx _) = case typeArr of
                                                        [Array tp] -> case typeIdx of
                                                                    [tp'] -> if elem tp' [TypeByte, TypeShort, TypeInt] then [tp] else typeLinkingFailure "Array: index is not an integer"
                                                                    _ -> typeLinkingFailure "Array Index Type typeLinkingFailure"
                                                        _ -> typeLinkingFailure "Array Type cannot be found"
    where
        typeArr = typeLinkingExpr db imps su arr 
        typeIdx = typeLinkingExpr db imps su idx
                
                
-- to check: allow use array of primitive type to cast
typeLinkingExpr db imps su (CastA casttp dim expr _) = case typeExpr of
                                                        [] -> typeLinkingFailure "CastA: cannot type linking the expression"
                                                        _ -> if null casting then [] else [targetType]
        where
            typeExpr = typeLinkingExpr db imps su expr
            targetType = if dim == Null then casttp else (Array casttp)
            casting = conversion db (head typeExpr) targetType

-- to do: is it possible cast from A to B?
typeLinkingExpr db imps su (CastB castexpr expr _) = if null typeCastExpr || null typeExpr || null casting then typeLinkingFailure "CastB: cannot type linking the expression" else typeCastExpr
        where
            typeCastExpr = typeLinkingExpr db imps su castexpr
            typeExpr = typeLinkingExpr db imps su expr
            casting = conversion db (head typeExpr) (head typeCastExpr)

-- to check: must be (Name [])?
typeLinkingExpr db imps su (CastC castnm _ expr _) = if null tps || null typeExpr || null casting then typeLinkingFailure "CastC: cannot type linking the expression" else [targetType]
        where
            tps = typeLinkingName db imps su castnm
            typeExpr = typeLinkingExpr db imps su expr
            targetType = Array (head tps) -- BUG?
            casting = conversion db (head typeExpr) targetType
            

typeLinkingExpr db imps su _ = [TypeVoid]

---------------------------------------------------------------------------------------------------------

typeLinkingName :: TypeNode -> [[String]] -> SemanticUnit -> Name -> [Type]
typeLinkingName db imps su (Name cname@(nm:remain)) = case typeLinkingName' db imps su (Name cname) of
                                                        [] -> typeLinkingFailure $ "Link Name failure: " ++ (show cname)
                                                        tps -> tps

typeLinkingName' :: TypeNode -> [[String]] -> SemanticUnit -> Name -> [Type]
typeLinkingName' db imps su (Name cname@(nm:remain)) = case syms'' of
                                                        [] -> case symsInheritance'' of
                                                                [] -> lookUpDB db imps su (nm:remain)
                                                                _ -> map symbolToType symsInheritance''
                                                        _ -> map symbolToType syms''
	where
                baseName = (typeToName . lookUpThis) su
		syms = [sym | sym <- lookUpSymbolTable su nm, not $ elem "cons" (symbolModifiers sym)]
                symsStatic = [sym | sym@(SYM mds scope _ _) <- syms, (init scope /= baseName) || (not $ elem "static" mds)] ++ [func | func@(FUNC mds _ _ _ _) <- syms]
                syms' = if scopeStatic su then symsStatic else syms
                syms'' = if remain == []
                            then syms'
                            else map symbol $ concat $ map (traverseInstanceEntry' db db) [((typeToName . localType) sym) ++ remain | sym@(SYM mds _ _ _) <- syms']
                
                Just thisNode = getTypeEntry db (typeToName . lookUpThis $ su)
                symsInheritance = [sym | sym <- map symbol (traverseInstanceEntry' db thisNode [nm]), not $ elem "cons" (symbolModifiers sym)]
                symsInheritanceStatic = [sym | sym@(SYM mds _ _ _) <- symsInheritance, elem "static" mds] ++ [func | func@(FUNC mds _ _ _ _) <- symsInheritance]
                symsInheritance' = if scopeStatic su then symsInheritanceStatic else symsInheritance
                symsInheritance'' = if remain == []
                            then symsInheritance'
                            else map symbol $ concat $ map (traverseInstanceEntry' db db) [((typeToName . localType) sym) ++ remain | sym@(SYM mds _ _ _) <- symsInheritance']

---------------------------------------------------------------------------------------------------------

lookUpThis :: SemanticUnit -> Type
lookUpThis su = if elem (kind su) [Class, Interface] then Object (Name (scope su)) else lookUpThis (inheritFrom su)

scopeStatic:: SemanticUnit -> Bool
scopeStatic su
    | elem kd [Package, Class, Interface] = True
    | otherwise = rst
    where
        kd = kind su
        rst = case kd of
                Method (FUNC mds _ _ _ _) -> elem "static" mds
                _ -> scopeStatic (inheritFrom su)
                    

lookUpSymbolTable :: SemanticUnit -> String -> [Symbol]
lookUpSymbolTable (Root _) str = []
lookUpSymbolTable su nm = case cur of
                            [] -> lookUpSymbolTable parent nm
                            _ -> cur
    where
        (SU _ _ st parent) = su
        cur = filter (\s -> (localName s) == nm) st

lookUpDB :: TypeNode -> [[String]] -> SemanticUnit -> [String] -> [Type]
lookUpDB db imps su cname
    | length tps' > 0 = tps'
    | otherwise = (map (symbolToType . symbol) $ nub tps)
        where
            ps = map (\i -> (take i cname, drop i cname)) [1..(length cname)]
            tps = concat $ map (\(pre, post) -> traverseInstanceEntry db (traverseFieldEntryWithImports db imps pre) post) ps
            tps' = map (TypeClass . Name) (lookUpType db imps cname)

------------------------------------------------------------------------------------

checkSameNameInEnvironment :: Environment -> Bool
checkSameNameInEnvironment ENVE = False
checkSameNameInEnvironment (ENV su [ENVE]) = checkSameNameUp su []
checkSameNameInEnvironment (ENV su []) = checkSameNameUp su []
checkSameNameInEnvironment (ENV su chs) = or $ map checkSameNameInEnvironment chs


checkSameNameUp :: SemanticUnit -> [Symbol] -> Bool
checkSameNameUp (Root _) accst = checkSameNameInSymbolTable accst
checkSameNameUp su@(SU _ kd st parent) accst = case kd of
                                                Method _ -> res || checkSameNameUp parent []
                                                Interface -> res || checkSameNameUp parent []
                                                Class -> res || checkSameNameUp parent []
                                                _ -> checkSameNameUp parent nextst
    where
        nextst = accst ++ st
        res = functionCheck || checkSameNameInSymbolTable nextst
        
        functionCheck = length cons /= (length . nub) cons || length funcs /= (length . nub) funcs
        cname = lookUpThis su
        cons = [(ln, pt) | f@(FUNC mds _ ln pt lt) <- st, elem "cons" mds]
        funcs = [(ln, pt) | f@(FUNC mds _ ln pt lt) <- st, not $ elem "cons" mds]


checkSameNameInSymbolTable :: [Symbol] -> Bool
checkSameNameInSymbolTable st = length nms /= (length . nub) nms
    where
        syms = [SYM mds ls nm tp | SYM mds ls nm tp <- st]
        nms = map localName syms
