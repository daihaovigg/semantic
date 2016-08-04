{-# LANGUAGE RankNTypes #-}
module Interpreter (Comparable, DiffConstructor, diffTerms) where

import Algorithm
import Data.Align.Generic
import Data.Functor.Foldable
import Data.Functor.Both
import Data.Hashable
import Data.RandomWalkSimilarity
import Data.Record
import Data.These
import Diff
import qualified Control.Monad.Free.Church as F
import Info
import Patch
import Prologue hiding (lookup)
import SES
import Syntax as S
import Term

-- | Returns whether two terms are comparable
type Comparable leaf annotation = Term leaf annotation -> Term leaf annotation -> Bool

-- | Constructs a diff from the CofreeF containing its annotation and syntax. This function has the opportunity to, for example, cache properties in the annotation.
type DiffConstructor leaf annotation = CofreeF (Syntax leaf) (Both annotation) (Diff leaf annotation) -> Diff leaf annotation

-- | Diff two terms recursively, given functions characterizing the diffing.
diffTerms :: (Eq leaf, Hashable leaf, Eq (Record fields), HasField fields Category)
  => DiffConstructor leaf (Record fields) -- ^ A function to wrap up & possibly annotate every produced diff.
  -> Comparable leaf (Record fields) -- ^ A function to determine whether or not two terms should even be compared.
  -> SES.Cost (Diff leaf (Record fields)) -- ^ A function to compute the cost of a given diff node.
  -> Term leaf (Record fields) -- ^ A term representing the old state.
  -> Term leaf (Record fields) -- ^ A term representing the new state.
  -> Diff leaf (Record fields)
diffTerms construct comparable cost a b = fromMaybe (replacing a b) $ diffComparableTerms construct comparable cost a b

diffComparableTerms :: (Eq leaf, Hashable leaf, Eq (Record fields), HasField fields Category) => DiffConstructor leaf (Record fields) -> Comparable leaf (Record fields) -> SES.Cost (Diff leaf (Record fields)) -> Term leaf (Record fields) -> Term leaf (Record fields) -> Maybe (Diff leaf (Record fields))
diffComparableTerms construct comparable cost = recur
  where recur a b
          | (category <$> a) == (category <$> b) = hylo construct runCofree <$> zipTerms a b
          | comparable a b = runAlgorithm construct recur cost getLabel (Just <$> algorithmWithTerms construct a b)
          | otherwise = Nothing
        getLabel (h :< t) = (category h, case t of
          Leaf s -> Just s
          _ -> Nothing)

-- | Construct an algorithm to diff a pair of terms.
algorithmWithTerms :: (TermF leaf (Both a) diff -> diff) -> Term leaf a -> Term leaf a -> Algorithm (Term leaf a) diff diff
algorithmWithTerms construct t1 t2 = case (unwrap t1, unwrap t2) of
  (Indexed a, Indexed b) -> byIndex Indexed a b
  (S.FunctionCall identifierA argsA, S.FunctionCall identifierB argsB) -> do
    identifier <- recursively identifierA identifierB
    byIndex (S.FunctionCall identifier) argsA argsB
  (S.Switch exprA casesA, S.Switch exprB casesB) -> do
    expr <- recursively exprA exprB
    byIndex (S.Switch expr) casesA casesB
  (S.Object a, S.Object b) -> byIndex S.Object a b
  (Commented commentsA a, Commented commentsB b) -> do
    wrapped <- sequenceA (recursively <$> a <*> b)
    byIndex (`Commented` wrapped) commentsA commentsB
  (Array a, Array b) -> byIndex Array a b
  (S.Class identifierA paramsA expressionsA, S.Class identifierB paramsB expressionsB) -> do
    identifier <- recursively identifierA identifierB
    params <- sequenceA (recursively <$> paramsA <*> paramsB)
    byIndex (S.Class identifier params) expressionsA expressionsB
  (S.Method identifierA paramsA expressionsA, S.Method identifierB paramsB expressionsB) -> do
    identifier <- recursively identifierA identifierB
    params <- Algorithm.byIndex paramsA paramsB
    expressions <- Algorithm.byIndex expressionsA expressionsB
    annotate $! S.Method identifier params expressions
  _ -> recursively t1 t2
  where annotate = pure . construct . (both (extract t1) (extract t2) :<)
        byIndex constructor a b = Algorithm.byIndex a b >>= annotate . constructor

-- | Run an algorithm, given functions characterizing the evaluation.
runAlgorithm :: (Functor f, GAlign f, Eq a, Eq annotation, Eq (f (Cofree f annotation)), Prologue.Foldable f, Traversable f, Hashable label)
  => (CofreeF f (Both annotation) (Free (CofreeF f (Both annotation)) (Patch (Cofree f annotation))) -> Free (CofreeF f (Both annotation)) (Patch (Cofree f annotation))) -- ^ A function to wrap up & possibly annotate every produced diff.
  -> (Cofree f annotation -> Cofree f annotation -> Maybe (Free (CofreeF f (Both annotation)) (Patch (Cofree f annotation)))) -- ^ A function to diff two subterms recursively, if they are comparable, or else return 'Nothing'.
  -> SES.Cost (Free (CofreeF f (Both annotation)) (Patch (Cofree f annotation))) -- ^ A function to compute the cost of a given diff node.
  -> (forall b. CofreeF f annotation b -> label) -- ^ A function to compute a label for a given term.
  -> Algorithm (Cofree f annotation) (Free (CofreeF f (Both annotation)) (Patch (Cofree f annotation))) a -- ^ The algorithm to run.
  -> a
runAlgorithm construct recur cost getLabel = F.iter $ \case
  Recursive a b f -> f (maybe (replacing a b) (construct . (both (extract a) (extract b) :<)) $ do
    aligned <- galign (unwrap a) (unwrap b)
    traverse (these (Just . deleting) (Just . inserting) recur) aligned)
  ByIndex as bs f -> f (ses recur cost as bs)
  BySimilarity as bs f -> f (rws recur getLabel as bs)
