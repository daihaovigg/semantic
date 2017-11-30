{-# LANGUAGE UndecidableInstances, AllowAmbiguousTypes, ConstraintKinds, DataKinds, FlexibleContexts, FlexibleInstances, MultiParamTypeClasses, ScopedTypeVariables, TypeApplications, TypeOperators, MonoLocalBinds #-}
module Abstract.Interpreter where

import Control.Effect
import Control.Monad.Effect hiding (run)
import Control.Monad.Effect.Env
import Control.Monad.Effect.Fail
import Control.Monad.Effect.Fresh
import Control.Monad.Effect.NonDetEff
import Control.Monad.Effect.Reader
import Control.Monad.Effect.State
import Control.Monad.Effect.Store
import Data.Abstract.Environment
import Data.Abstract.Eval
import Data.Abstract.FreeVariables
import Data.Abstract.Value
import Data.Function (fix)
import Data.Semigroup
import qualified Data.Set as Set
import Data.Term
import Prelude hiding (fail)


type Interpreter v = '[Fresh, Fail, NonDetEff, State (Store (LocationFor v) v), Reader (Set.Set (Address (LocationFor v) v)), Reader (Environment (LocationFor v) v)]

type MonadInterpreter v m = (MonadEnv v m, MonadStore v m, MonadFail m)

type EvalResult v = Final (Interpreter v) v

type Eval' t m v = (v -> m v) -> t -> m v

-- Evaluate an expression.
-- Example:
--    evaluate @Type <term>
--    evaluate @(Value (Data.Union.Union Language.Python.Assignment2.Syntax) (Record Location) Precise) <term>
evaluate :: forall v syntax ann
         . ( Ord v
           , Functor syntax
           , Semigroup (Cell (LocationFor v) v)
           , FreeVariables1 syntax
           , MonadAddress (LocationFor v) (Eff (Interpreter v))
           , Eval (Term syntax ann) v (Eff (Interpreter v)) syntax
           )
         => Term syntax ann
         -> EvalResult v
evaluate = run @(Interpreter v) . fix ev pure

ev ::
     ( Functor syntax
     , FreeVariables1 syntax
     , Eval (Term syntax ann) v m syntax
     )
     => Eval' (Term syntax ann) m v -> Eval' (Term syntax ann) m v
ev recur yield = eval recur yield . unTerm

evCollect :: forall t v m
          .  ( Ord (LocationFor v)
             , Foldable (Cell (LocationFor v))
             , MonadStore v m
             , MonadGC v m
             , ValueRoots (LocationFor v) v
             )
          => (Eval' t m v -> Eval' t m v)
          -> Eval' t m v
          -> Eval' t m v
evCollect ev0 ev' yield e = do
  roots <- askRoots :: m (Set.Set (Address (LocationFor v) v))
  v <- ev0 ev' yield e
  modifyStore (gc (roots <> valueRoots v))
  return v

evRoots :: forall v m syntax ann
        .  ( Ord (LocationFor v)
           , MonadEnv v m
           , MonadGC v m
           , ValueRoots (LocationFor v) v
           , Eval (Term syntax ann) v m (TermF syntax ann)
           , FreeVariables1 syntax
           , Functor syntax
           )
        => Eval' (Term syntax ann) m v
        -> Eval' (Term syntax ann) m v
evRoots ev' yield = eval ev' yield . unTerm

gc :: (Ord (LocationFor a), Foldable (Cell (LocationFor a)), ValueRoots (LocationFor a) a) => Set.Set (Address (LocationFor a) a) -> Store (LocationFor a) a -> Store (LocationFor a) a
gc roots store = storeRestrict store (reachable roots store)

reachable :: (Ord (LocationFor a), Foldable (Cell (LocationFor a)), ValueRoots (LocationFor a) a) => Set.Set (Address (LocationFor a) a) -> Store (LocationFor a) a -> Set.Set (Address (LocationFor a) a)
reachable roots store = go roots mempty
  where go set seen = case Set.minView set of
          Nothing -> seen
          Just (a, as)
            | Just values <- storeLookupAll a store -> go (Set.difference (foldr ((<>) . valueRoots) mempty values <> as) seen) (Set.insert a seen)
            | otherwise -> go seen (Set.insert a seen)
