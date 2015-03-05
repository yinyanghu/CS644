module Hierarchy where

import Control.Monad
import Data.Maybe
import Data.List

import AST
import Environment
import TypeDatabase
import Util

type HierarchyError = Maybe String

checkHierarchies :: [CompilationUnit] -> TypeNode -> HierarchyError
checkHierarchies units typeDB = msum $ map (\unit -> checkHierarchy unit typeDB) units

checkHierarchy :: CompilationUnit -> TypeNode -> HierarchyError
checkHierarchy unit typeDB
  | isJust implementError = implementError
  | isJust extendError = extendError
  | otherwise = Nothing
  where implementError = checkImplements unit typeDB
        extendError = checkExtends unit typeDB

checkImplements :: CompilationUnit -> TypeNode -> HierarchyError
checkImplements unit@(Comp _ _ (CLS _ clsName _ implemented _ _ _ _) _) typeDB
  | not . null $ implementedClasses = Just $ "Class " ++ clsName ++ " cannot implement class " ++ (localName $ head implementedClasses)
  | nub implementedNames /= implementedNames = Just $ "Class " ++ clsName ++ " implements the same interface twice"
  | otherwise = Nothing
  where unitImports = visibleImports unit
        implementedNames = map (traverseTypeEntryWithImports typeDB unitImports) implemented
        implementedNodes = mapMaybe (getTypeEntry typeDB) (map head implementedNames)
        implementedSymbols = map symbol implementedNodes
        implementedClasses = filter isClass implementedSymbols
checkImplements _ _ = Nothing

checkExtends :: CompilationUnit -> TypeNode -> HierarchyError
checkExtends unit@(Comp _ _ (CLS _ clsName (Just extendee) _ _ _ _ _) _) typeDB
  | isNothing extendedUnitMaybe = Just $ "Class " ++ clsName ++ " tried to extend non-existent class " ++ (show extendee)
  | isInterface extendedClass = Just $ "Class " ++ clsName ++ " cannot extend interface " ++ (interfaceName extendedClass)
  | "final" `elem` (modifiers extendedClass) = Just $ "Class " ++ clsName ++ " cannot extend final class " ++ (className extendedClass)
  | extendedUnit == unit = Just $ "Class " ++ clsName ++ " cannot extend itself"
  | null hierarchyChain = Just $ "Class " ++ clsName ++ " has a circular extend reference"
  | otherwise = Nothing
  where extendedUnitMaybe = getClassSuper unit typeDB
        extendedUnit = fromJust extendedUnitMaybe
        extendedClass = definition extendedUnit
        hierarchyChain = getClassHierarchy unit typeDB

checkExtends unit@(Comp _ _ (ITF _ itfName extended _ _) _) typeDB
  | not . null $ extendedClasses = Just $ "Interface " ++ itfName ++ " cannot extend class " ++ (show $ head extendedClasses)
  | nub extendedClasses /= extendedClasses = Just $ "Interface " ++ itfName ++ " extends the same interface twice"
  | ownName `elem` extendedNames = Just $ "Interface " ++ itfName ++ " cannot extend itself"
  | null hierarchyChain = Just $ "Interface " ++ itfName ++ " extends a circular extend chain"
  | otherwise = Nothing
  where unitImports = visibleImports unit
        ownName = traverseTypeEntryWithImports typeDB unitImports [itfName]
        extendedNames = map (traverseTypeEntryWithImports typeDB unitImports) extended
        extendedNodes = mapMaybe (getTypeEntry typeDB) (map head extendedNames)
        extendedSymbols = map symbol extendedNodes
        extendedClasses = filter isClass extendedSymbols
        hierarchyChain = getInterfaceSupers unit typeDB
checkExtends _ _ = Nothing

getClassSuper :: CompilationUnit -> TypeNode -> Maybe CompilationUnit
getClassSuper unit@(Comp _ _ (CLS _ clsName (Just extendee) _ _ _ _ _) _) typeDB
  | null extendedName = Nothing
  | not extendedNodeExists = Nothing
  | otherwise = Just extendedUnit
  where classImports = visibleImports unit
        extendedName = traverseTypeEntryWithImports typeDB classImports extendee
        extendedNode = getTypeEntry typeDB (head extendedName)
        extendedNodeExists = isJust extendedNode
        extendedUnit = astUnit . symbol . fromJust $ extendedNode
getClassSuper _ _ = Nothing

getInterfaceSupers :: CompilationUnit -> TypeNode -> [CompilationUnit]
getInterfaceSupers unit typeDB = getInterfaceSupers' unit typeDB []

getInterfaceSupers' :: CompilationUnit -> TypeNode -> [CompilationUnit] -> [CompilationUnit]
getInterfaceSupers' unit@(Comp _ _ (ITF _ _ extended _ _) _) typeDB hierarchy
  | null extended = [unit]
  | unit `elem` hierarchy = []
  | any null extendedInterfaceExtensions = []
  | otherwise = nub (unit : (concat extendedInterfaceExtensions))
  where unitImports = visibleImports unit
        extendedNames = map (traverseTypeEntryWithImports typeDB unitImports) extended
        extendedNodes = mapMaybe (getTypeEntry typeDB) (map head extendedNames)
        extendedSymbols = map symbol extendedNodes
        extendedInterfaces = map astUnit extendedSymbols
        newHierarchy = unit : hierarchy
        extendedInterfaceExtensions = map (\x -> getInterfaceSupers' x typeDB newHierarchy) extendedInterfaces
getInterfaceSupers' _ _ _ = []

getClassHierarchy :: CompilationUnit -> TypeNode -> [CompilationUnit]
getClassHierarchy unit typeDB = getClassHierarchy' unit typeDB [unit]

getClassHierarchy' :: CompilationUnit -> TypeNode -> [CompilationUnit] -> [CompilationUnit]
getClassHierarchy' unit@(Comp _ _ (CLS _ _ _ implemented _ _ _ _) _) typeDB hierarchy
  | isNothing extendedClassMaybe = hierarchy
  | extendedClass `elem` hierarchy = []
  | otherwise = getClassHierarchy' extendedClass typeDB (hierarchy ++ [extendedClass])
  where extendedClassMaybe = getClassSuper unit typeDB
        extendedClass = fromJust extendedClassMaybe


