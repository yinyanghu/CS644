module Inheritance where

import           Prelude hiding (lookup)

import           Data.List     (intercalate, nub, sort)
import           Data.Map      (Map, fromList, toAscList, lookup)
import           Data.Maybe

import           AST (typeToName, Type(..))
import           Environment
import           Hierarchy
import           TypeDatabase
import           Util

instanceMiscOffset = 3

generateLabelFromSYM :: Symbol -> Int -> String
generateLabelFromSYM (SYM mds ls ln _) i = if elem "native" mds
                                             then case ln of
                                                    "object size" -> intercalate "_" (["native", "field", last ls, md, "object_size", show i])
                                             else intercalate "_" (["field", last ls, md, ln, show i])
  where
    md = if elem "static" mds
            then "static"
            else "instance"

generateLabelFromFUNC :: Symbol -> Int -> String
generateLabelFromFUNC (FUNC mds ls ln _ _) i = if elem "native" mds
                                                 then case ln of
                                                        "malloc" -> "__malloc"
                                                        "exception" -> "__exception"
                                                        "nativeWrite" -> "NATIVEjava.io.OutputStream.nativeWrite"
                                                 else intercalate "_" (["function", last ls, md, ln, show i])
  where
    md = if (elem "static" mds) || (elem "cons" mds)
            then "static"
            else "instance"

createTypeID :: TypeNode -> Map Symbol Int
createTypeID db = fromList (zip syms [0..])
  where
    syms = (sort . (map symbol) . dumpDBNodes) db

createTypeSize :: TypeNode -> Map Symbol Int
createTypeSize db = fromList (map (\tp -> (generateTypeSizeSymbol $ symbol tp, instanceMiscOffset + (length $ generateInstanceFieldOffset (subNodes tp)))) tps)
  where
    tps = filter isCLNode $ dumpDBNodes db

createStaticSYMASM :: TypeNode -> [String]
createStaticSYMASM db = ["global " ++ label ++ "\n" ++ label ++ ":\n" ++ "dd " ++ (show $ getSize sym ) ++ "\n" | (sym, label) <- pairs]
  where
    pairs = toAscList $ createStaticFieldLabel db
    sizeMap = createTypeSize db
    getSize sym = case lookup sym sizeMap of
                    Nothing -> 0
                    Just size -> 4 * size

generateTypeSizeSymbol :: Symbol -> Symbol
generateTypeSizeSymbol (CL _ _ lt _) = (SYM ["static", "native"] (typeToName lt) "object size" AST.TypeInt)


generateInstanceFieldOffset :: [TypeNode] -> [(Symbol, Int)]
generateInstanceFieldOffset nodes = zip syms [instanceMiscOffset..]
  where
    syms = reverse $ filter (\(SYM mds _ _ _) -> not $ elem "static" mds) $ map symbol $ filter isSYMNode nodes

createInstanceFieldOffset :: TypeNode -> Map Symbol Int
createInstanceFieldOffset db = if length offsets == length offsets'
                                  then  offsetMap
                                  else  error $ "inconsistency detected" ++ (show offsets) ++ (show offsets')
  where
    tps = filter isCLNode $ dumpDBNodes db
    offsets = nub $ concat $ map (\tp -> generateInstanceFieldOffset (subNodes tp)) tps
    offsetMap = fromList offsets
    offsets' = toAscList offsetMap

createStaticFieldLabel :: TypeNode -> Map Symbol String
createStaticFieldLabel db = fromList [(sym, generateLabelFromSYM sym i) | (sym, i) <- zip syms'' [0..]]
  where
    tps = filter isCLNode $ dumpDBNodes db
    syms' = map (generateTypeSizeSymbol . symbol) tps
    syms = nub $ filter (\(SYM mds _ _ _) -> elem "static" mds) $ map symbol $ filter isSYMNode $ concat $ map subNodes tps
    syms'' = syms' ++ syms


createInstanceFUNCID :: TypeNode -> Map Symbol Int
createInstanceFUNCID db = fromList (zip syms [0.. (length syms)])
  where
    syms = sort $ nub $ filter (\(FUNC mds _ _ _ _) -> (not $ elem "static" mds) && (not $ elem "cons" mds)) $ map symbol $ filter isFUNCNode $ concat $ map subNodes (dumpDBNodes db)

createStaticFUNCID :: TypeNode -> Map Symbol Int
createStaticFUNCID db = fromList (zip syms [0..])
  where
    syms = sort $ filter (\(FUNC mds _ _ _ _) -> (elem "static" mds) || (elem "cons" mds)) $ map symbol $ filter isFUNCNode $ concat $ map subNodes (dumpDBNodes db)
    --syms' = (symbol runtimeMalloc):syms

createStaticFUNCLabel :: TypeNode -> Map Symbol String
createStaticFUNCLabel db = fromList pairs
  where
    funcMap = createStaticFUNCID db
    pairs = map (\(sym, i) -> (sym, generateLabelFromFUNC sym i)) (toAscList funcMap)

createInstanceFUNCLabel :: TypeNode -> Map Symbol String
createInstanceFUNCLabel db = fromList pairs
  where
    funcMap = createInstanceFUNCID db
    pairs = map (\(sym, i) -> (sym, generateLabelFromFUNC sym i)) (toAscList funcMap)

createTypeCharacteristicBM :: TypeNode -> [Bool]
createTypeCharacteristicBM db = map snd smap
  where
    syms = (sort . (map symbol) . dumpDBNodes) db
    smap = [(x * (length syms) + y, isA db (syms !! x) (syms !! y)) | x <- init [0..length syms], y <- init [0..length syms]]

updateFUNC :: Symbol -> [Symbol] -> Maybe Symbol
updateFUNC func imps = case filter (\imp -> funcToSigOrd func == funcToSigOrd imp) imps of
                         [imp] -> Just imp
                         _  -> Nothing

updateFUNCTable :: [Symbol] -> [Symbol] -> [Maybe Symbol]
updateFUNCTable funcs imps = map (\func -> updateFUNC func imps) funcs

createInstanceFUNCTable :: TypeNode -> [(Symbol, [Maybe Symbol])]
createInstanceFUNCTable db = map (\(tp, imps) -> (tp, updateFUNCTable funcs imps)) pairs
  where
    tps = ((sortOn symbol) . (filter isCLNode) . dumpDBNodes) db
    funcsMap = createInstanceFUNCID db
    funcs = map fst (toAscList funcsMap)
    pairs = map (\tp -> (symbol tp, map symbol (filter isFUNCNode $ subNodes tp))) tps

generateEdgeFromPairs :: [(Symbol, [Symbol])] -> [([String], [String])]
generateEdgeFromPairs [] = []
generateEdgeFromPairs ((cSYM, syms):remain) = edges' ++ (generateEdgeFromPairs remain)
  where
    edges = nub [(symbolToCN cSYM, symbolToCN sym) | sym <- syms]
    edges' = filter (\(a, b) -> a /= b) edges

generateClassOrdering :: [[String]] -> [([String], [String])] -> [[String]]
generateClassOrdering [] _ = []
generateClassOrdering nodes edges = case cand of
                                      node:_ -> node:(generateClassOrdering (filter (node /=) nodes) edges')
                                      [] -> error $ "loop: " ++ (show edges)
  where
    edges' = filter (\(e1, e2) -> (elem e1 nodes) || (elem e2 nodes)) edges
    cand = filter (\node -> not $ elem node (map fst edges')) nodes
