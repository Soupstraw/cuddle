{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}

-- | Module for building CDDL in Haskell
--
-- Compared to the builders, this is less about creating a DSL for CDDL in
-- Haskell as about using Haskell's higher-level capabilities to express CDDL
-- constraints. So we ditch a bunch of CDDL concepts where we can instead use
-- Haskell's capabilities there.
module Codec.CBOR.Cuddle.Huddle
  ( -- * Core Types
    Huddle,
    Rule,
    Named,
    IsType0 (..),
    Value (..),

    -- * Rules and assignment
    (=:=),
    (=:~),
    comment,

    -- * Maps
    (==>),
    mp,
    asKey,
    idx,

    -- * Arrays
    a,
    arr,

    -- * Groups
    Group,
    grp,

    -- * Quantification
    CanQuantify (..),
    opt,

    -- * Choices
    (//),
    (/),
    seal,
    sarr,
    smp,

    -- * Literals
    Literal,
    bstr,
    int,
    text,

    -- * Ctl operators
    IsSizeable,
    sized,
    cbor,
    le,

    -- * Ranged
    (...),

    -- * Tagging
    tag,

    -- * Generics
    GRuleCall,
    binding,
    binding2,

    -- * Conversion to CDDL
    collectFrom,
    toCDDL,
  )
where

import Codec.CBOR.Cuddle.CDDL (CDDL)
import Codec.CBOR.Cuddle.CDDL qualified as C
import Codec.CBOR.Cuddle.CDDL.CtlOp qualified as CtlOp
import Control.Monad (when)
import Control.Monad.State (MonadState (get), execState, modify)
import Data.ByteString (ByteString)
import Data.Default.Class (Default (..))
import Data.Generics.Product (HasField, field)
import Data.Int (Int64)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as HaskMap
import Data.String (IsString (fromString))
import Data.Text qualified as T
import Data.Tuple.Optics (Field1 (..), Field2 (..), Field3 (..))
import Data.Void (Void)
import GHC.Generics (Generic)
import GHC.IsList (IsList (Item, fromList, toList))
import Optics.Core (over, view, (%~), (&), (.~))
import Prelude hiding ((/))

data Named a = Named
  { name :: T.Text,
    value :: a,
    description :: Maybe T.Text
  }
  deriving (Functor, Generic)

-- | Add a description to a rule, to be included as a comment.
comment :: T.Text -> Named a -> Named a
comment desc n = n & field @"description" .~ Just desc

instance Show (Named a) where
  show (Named n _ _) = T.unpack n

type Rule = Named Type0

-- | Top-level Huddle type is a list of rules.
data Huddle = Huddle
  { rules :: NE.NonEmpty Rule,
    groups :: [Named Group],
    gRules :: [GRuleDef]
  }
  deriving (Show)

-- | This instance is mostly used for testing
instance IsList Huddle where
  type Item Huddle = Rule
  fromList [] = error "Huddle: Cannot have empty ruleset"
  fromList (x : xs) = Huddle (x NE.:| xs) mempty mempty

  toList = NE.toList . (.rules)

data Choice a
  = NoChoice a
  | ChoiceOf a (Choice a)
  deriving (Eq, Show, Functor, Foldable, Traversable)

choiceToList :: Choice a -> [a]
choiceToList (NoChoice x) = [x]
choiceToList (ChoiceOf x xs) = x : choiceToList xs

choiceToNE :: Choice a -> NE.NonEmpty a
choiceToNE (NoChoice c) = NE.singleton c
choiceToNE (ChoiceOf c cs) = c NE.:| choiceToList cs

data Key
  = LiteralKey Literal
  | TypeKey Type2
  deriving (Show)

-- | Instance for the very general case where we use text keys
instance IsString Key where
  fromString = LiteralKey . LText . T.pack

-- | Use a number as a key
idx :: Int64 -> Key
idx = LiteralKey . LInt

asKey :: (IsType0 r) => r -> Key
asKey r = case toType0 r of
  NoChoice x -> TypeKey x
  ChoiceOf _ _ -> error "Cannot use a choice of types as a map key"

data MapEntry = MapEntry
  { key :: Key,
    value :: Type0,
    quantifier :: Occurs
  }
  deriving (Generic, Show)

newtype MapChoice = MapChoice {unMapChoice :: [MapEntry]}
  deriving (Show)

instance IsList MapChoice where
  type Item MapChoice = MapEntry

  fromList = MapChoice
  toList (MapChoice m) = m

type Map = Choice MapChoice

data ArrayEntry = ArrayEntry
  { -- | Arrays can have keys, but they have no semantic meaning. We add them
    -- here because they can be illustrative in the generated CDDL.
    key :: Maybe Key,
    value :: Type0,
    quantifier :: Occurs
  }
  deriving (Generic, Show)

instance Num ArrayEntry where
  fromInteger i =
    ArrayEntry
      Nothing
      (NoChoice . T2Literal . Unranged $ LInt (fromIntegral i))
      def
  (+) = error "Cannot treat ArrayEntry as a number"
  (*) = error "Cannot treat ArrayEntry as a number"
  abs = error "Cannot treat ArrayEntry as a number"
  signum = error "Cannot treat ArrayEntry as a number"
  negate = error "Cannot treat ArrayEntry as a number"

newtype ArrayChoice = ArrayChoice {unArrayChoice :: [ArrayEntry]}
  deriving (Show, Monoid, Semigroup)

instance IsList ArrayChoice where
  type Item ArrayChoice = ArrayEntry

  fromList = ArrayChoice
  toList (ArrayChoice l) = l

type Array = Choice ArrayChoice

newtype Group = Group {unGroup :: [Type0]}
  deriving (Show, Monoid, Semigroup)

instance IsList Group where
  type Item Group = Type0

  fromList = Group
  toList (Group l) = l

data Type2
  = T2Basic Constrained
  | T2Literal Ranged
  | T2Map Map
  | T2Array Array
  | T2Tagged (Tagged Type0)
  | T2Ref (Named Type0)
  | T2Group (Named Group)
  | -- | Call to a generic rule, binding arguments
    T2Generic GRuleCall
  | -- | Reference to a generic parameter within the body of the definition
    T2GenericRef GRef
  deriving (Show)

type Type0 = Choice Type2

instance Num Type0 where
  fromInteger i = NoChoice . T2Literal . Unranged $ LInt (fromIntegral i)
  (+) = error "Cannot treat Type0 as a number"
  (*) = error "Cannot treat Type0 as a number"
  abs = error "Cannot treat Type0 as a number"
  signum = error "Cannot treat Type0 as a number"
  negate = error "Cannot treat Type0 as a number"

-- | Occurrence bounds.
data Occurs = Occurs
  { lb :: Maybe Int,
    ub :: Maybe Int
  }
  deriving (Eq, Generic, Show)

instance Default Occurs where
  def = Occurs Nothing Nothing

-- | Type-parametrised value type handling CBOR primitives. This is used to
-- constrain the set of constraints which can apply to a given postlude type.
data Value a where
  VBool :: Value Bool
  VUInt :: Value Int
  VNInt :: Value Int
  VInt :: Value Int
  VHalf :: Value Float
  VFloat :: Value Float
  VDouble :: Value Double
  VBytes :: Value ByteString
  VText :: Value T.Text
  VAny :: Value Void
  VNil :: Value Void

deriving instance Show (Value a)

--------------------------------------------------------------------------------
-- Literals
--------------------------------------------------------------------------------

data Literal where
  LInt :: Int64 -> Literal
  LText :: T.Text -> Literal
  LFloat :: Float -> Literal
  LDouble :: Double -> Literal
  LBytes :: ByteString -> Literal
  deriving (Show)

int :: Int64 -> Literal
int = LInt

bstr :: ByteString -> Literal
bstr = LBytes

text :: T.Text -> Literal
text = LText

--------------------------------------------------------------------------------
-- Constraints and Ranges
--------------------------------------------------------------------------------

-- | We only allow constraining basic values.
data Constrained where
  Constrained ::
    forall a.
    { value :: Value a,
      constraint :: ValueConstraint a
    } ->
    Constrained

deriving instance Show Constrained

unconstrained :: Value a -> Constrained
unconstrained v = Constrained v def

-- | A constraint on a 'Value' is something applied via CtlOp or RangeOp on a
-- Type2, forming a Type1.
data ValueConstraint a = ValueConstraint
  { applyConstraint :: C.Type2 -> C.Type1,
    showConstraint :: String
  }

instance Show (ValueConstraint a) where
  show x = x.showConstraint

instance Default (ValueConstraint a) where
  def =
    ValueConstraint
      { applyConstraint = (`C.Type1` Nothing),
        showConstraint = ""
      }

-- | Marker that we can apply the size CtlOp to something. Not intended for
-- export.
class IsSizeable a

instance IsSizeable Int

instance IsSizeable ByteString

instance IsSizeable T.Text

-- | Things which can be used on the RHS of the '.size' operator.
class IsSize a where
  sizeAsCDDL :: a -> C.Type2
  sizeAsString :: a -> String

instance IsSize Int where
  sizeAsCDDL = C.T2Value . C.VNum
  sizeAsString = show

instance IsSize (Int, Int) where
  sizeAsCDDL (x, y) =
    C.T2Group
      ( C.Type0
          ( C.Type1
              (C.T2Value (C.VNum x))
              (Just (C.RangeOp C.Closed, C.T2Value (C.VNum y)))
              NE.:| []
          )
      )
  sizeAsString (x, y) = show x <> ".." <> show y

-- | Declare a size constraint on an int-style type.
sized :: (IsSizeable a, IsSize s) => Value a -> s -> Constrained
sized v sz =
  Constrained v $
    ValueConstraint
      { applyConstraint = \t2 ->
          C.Type1
            t2
            (Just (C.CtrlOp CtlOp.Size, sizeAsCDDL sz)),
        showConstraint = ".size " <> sizeAsString sz
      }

cbor :: Value ByteString -> Rule -> Constrained
cbor v (Named n _ _) =
  Constrained v $
    ValueConstraint
      { applyConstraint = \t2 ->
          C.Type1
            t2
            (Just (C.CtrlOp CtlOp.Cbor, C.T2Name (C.Name n) Nothing)),
        showConstraint = ".cbor " <> T.unpack n
      }

le :: Value Int -> Int64 -> Constrained
le v bound =
  Constrained v $
    ValueConstraint
      { applyConstraint = \t2 ->
          C.Type1
            t2
            (Just (C.CtrlOp CtlOp.Le, C.T2Value (C.VNum $ fromIntegral bound))),
        showConstraint = ".le " <> show bound
      }

-- Ranges

data Ranged where
  Ranged ::
    { lb :: Literal,
      ub :: Literal,
      bounds :: C.RangeBound
    } ->
    Ranged
  Unranged :: Literal -> Ranged
  deriving (Show)

-- | Establish a closed range bound. Currently specialised to Int for type
-- inference purposes.
(...) :: Int64 -> Int64 -> Ranged
l ... u = Ranged (LInt l) (LInt u) C.Closed

infixl 9 ...

--------------------------------------------------------------------------------
-- Syntax
--------------------------------------------------------------------------------

class IsType0 a where
  toType0 :: a -> Type0

instance IsType0 Rule where
  toType0 = NoChoice . T2Ref

instance IsType0 (Choice Type2) where
  toType0 = id

instance IsType0 Constrained where
  toType0 = NoChoice . T2Basic

instance IsType0 Map where
  toType0 = NoChoice . T2Map

instance IsType0 MapChoice where
  toType0 = NoChoice . T2Map . NoChoice

instance IsType0 Array where
  toType0 = NoChoice . T2Array

instance IsType0 ArrayChoice where
  toType0 = NoChoice . T2Array . NoChoice

instance IsType0 Ranged where
  toType0 = NoChoice . T2Literal

instance IsType0 Literal where
  toType0 = NoChoice . T2Literal . Unranged

-- We also allow going directly from primitive types to Type2
instance IsType0 Int64 where
  toType0 = NoChoice . T2Literal . Unranged . LInt

instance IsType0 T.Text where
  toType0 :: T.Text -> Type0
  toType0 = NoChoice . T2Literal . Unranged . LText

instance IsType0 ByteString where
  toType0 = NoChoice . T2Literal . Unranged . LBytes

instance IsType0 Float where
  toType0 = NoChoice . T2Literal . Unranged . LFloat

instance IsType0 Double where
  toType0 = NoChoice . T2Literal . Unranged . LDouble

instance IsType0 (Value a) where
  toType0 = NoChoice . T2Basic . unconstrained

instance IsType0 (Named Group) where
  toType0 = NoChoice . T2Group

instance IsType0 GRuleCall where
  toType0 = NoChoice . T2Generic

instance IsType0 GRef where
  toType0 = NoChoice . T2GenericRef

instance (IsType0 a) => IsType0 (Tagged a) where
  toType0 = NoChoice . T2Tagged . fmap toType0

class CanQuantify a where
  -- | Apply a lower bound
  (<+) :: Int -> a -> a

  -- | Apply an upper bound
  (+>) :: a -> Int -> a

infixl 8 <+

infixr 7 +>

opt :: (CanQuantify a) => a -> a
opt r = 0 <+ r +> 1

instance CanQuantify Occurs where
  lb <+ (Occurs _ ub) = Occurs (Just lb) ub
  (Occurs lb _) +> ub = Occurs lb (Just ub)

instance CanQuantify ArrayEntry where
  lb <+ ae = ae & field @"quantifier" %~ (lb <+)
  ae +> ub = ae & field @"quantifier" %~ (+> ub)

instance CanQuantify MapEntry where
  lb <+ ae = ae & field @"quantifier" %~ (lb <+)
  ae +> ub = ae & field @"quantifier" %~ (+> ub)

-- | A quantifier on a choice can be rewritten as a choice of quantifiers
instance (CanQuantify a) => CanQuantify (Choice a) where
  lb <+ c = fmap (lb <+) c
  c +> ub = fmap (+> ub) c

class IsEntryLike a where
  fromMapEntry :: MapEntry -> a

instance IsEntryLike MapEntry where
  fromMapEntry = id

instance IsEntryLike ArrayEntry where
  fromMapEntry me =
    ArrayEntry
      { key = Just me.key,
        value =
          me.value,
        quantifier = me.quantifier
      }

instance IsEntryLike Type0 where
  fromMapEntry = (.value)

(==>) :: (IsType0 a, IsEntryLike me) => Key -> a -> me
k ==> gc =
  fromMapEntry
    MapEntry
      { key = k,
        value = toType0 gc,
        quantifier = def
      }

infixl 9 ==>

-- | Assign a rule
(=:=) :: (IsType0 a) => T.Text -> a -> Rule
n =:= b = Named n (toType0 b) Nothing

infixl 1 =:=

(=:~) :: T.Text -> Group -> Named Group
n =:~ b = Named n b Nothing

infixl 1 =:~

class IsGroupOrArrayEntry a where
  toGroupOrArrayEntry :: (IsType0 x) => x -> a

instance IsGroupOrArrayEntry ArrayEntry where
  toGroupOrArrayEntry x =
    ArrayEntry
      { key = Nothing,
        value = toType0 x,
        quantifier = def
      }

instance IsGroupOrArrayEntry Type0 where
  toGroupOrArrayEntry = toType0

-- | Explicitly cast an item in an Array as an ArrayEntry.
a :: (IsType0 a, IsGroupOrArrayEntry e) => a -> e
a = toGroupOrArrayEntry

--------------------------------------------------------------------------------
-- Choices
--------------------------------------------------------------------------------
class IsChoosable a b | a -> b where
  toChoice :: a -> Choice b

instance IsChoosable (Choice a) a where
  toChoice = id

instance IsChoosable ArrayChoice ArrayChoice where
  toChoice = NoChoice

instance IsChoosable MapChoice MapChoice where
  toChoice = NoChoice

instance IsChoosable Type2 Type2 where
  toChoice = NoChoice

instance IsChoosable Rule Type2 where
  toChoice = toChoice . T2Ref

instance IsChoosable GRuleCall Type2 where
  toChoice = toChoice . T2Generic

instance IsChoosable GRef Type2 where
  toChoice = toChoice . T2GenericRef

instance IsChoosable ByteString Type2 where
  toChoice = toChoice . T2Literal . Unranged . LBytes

instance IsChoosable Constrained Type2 where
  toChoice = toChoice . T2Basic

instance (IsType0 a) => IsChoosable (Tagged a) Type2 where
  toChoice = toChoice . T2Tagged . fmap toType0

instance IsChoosable Literal Type2 where
  toChoice = toChoice . T2Literal . Unranged

instance IsChoosable (Value a) Type2 where
  toChoice = toChoice . T2Basic . unconstrained

instance IsChoosable (Seal Array) Type2 where
  toChoice (Seal x) = NoChoice $ T2Array x

instance IsChoosable (Seal Map) Type2 where
  toChoice (Seal m) = NoChoice $ T2Map m

instance IsChoosable (Seal ArrayChoice) Type2 where
  toChoice (Seal m) = NoChoice . T2Array $ NoChoice m

instance IsChoosable (Seal MapChoice) Type2 where
  toChoice (Seal m) = NoChoice . T2Map $ NoChoice m

(//) :: (IsChoosable a c, IsChoosable b c) => a -> b -> Choice c
x // b = go (toChoice x) (toChoice b)
  where
    go (NoChoice x') b' = ChoiceOf x' b'
    go (ChoiceOf x' b') c = ChoiceOf x' (go b' c)

-- Choices within maps or arrays
--
-- Maps and arrays allow an "internal" choice - as per [1, 'a' // 2, 'b']. This
-- means that the array can be either [1, 'a'] or [2, 'b']. Since this would not
-- work within Haskell's array syntax, we instead pull the option outside of the
-- array, as with [1, 'a'] // [2, 'b'].
--
-- This, however, leaves us with a problem. When we write [1, 'a'] // [2, 'b']
-- we have two possible interpretations - as a top-level choice (in CDDL terms,
-- a choice in the 'Type0'. In Huddle terms, as a Choice Array) or as a choice
-- inside the array (in CDDL terms, a choice inside the Group. In Huddle terms,
-- as a Choice ArrayChoice (itself an Array!)).
--
-- To resolve this, we allow "sealing" an array or map. A sealed array or map
-- will no longer absorb (//).

newtype Seal a = Seal a

-- | Seal an array or map, indicating that it will no longer absorb (//). This
-- is needed if you wish to include an array or map inside a top-level choice.
seal :: a -> Seal a
seal = Seal

-- | This function is used solely to resolve type inference by explicitly
-- identifying something as an array.
arr :: ArrayChoice -> ArrayChoice
arr = id

-- | Create and seal an array, marking it as accepting no additional choices
sarr :: ArrayChoice -> Seal Array
sarr = seal . NoChoice

mp :: MapChoice -> MapChoice
mp = id

-- | Create and seal a map, marking it as accepting no additional choices.
smp :: MapChoice -> Seal Map
smp = seal . NoChoice

grp :: Group -> Group
grp = id

-- | Allow a choice within an array or map entry.
(/) ::
  ( IsType0 rt,
    HasField "value" e e Type0 Type0
  ) =>
  e ->
  rt ->
  e
ae / rt = ae & field @"value" %~ (// toType0 rt)

--------------------------------------------------------------------------------
-- Tagged types
--------------------------------------------------------------------------------

-- | A tagged type carries an optional tag
data Tagged a = Tagged (Maybe Int) a
  deriving (Show, Functor)

-- | Tag a CBOR item with a CDDL minor type. Thus, `tag n x` is equivalent to
-- `#6.n(x)` in CDDL.
tag :: Int -> a -> Tagged a
tag mi = Tagged (Just mi)

--------------------------------------------------------------------------------
-- Generics
--------------------------------------------------------------------------------

newtype GRef = GRef T.Text
  deriving (Show)

freshName :: Int -> GRef
freshName ix =
  GRef $
    T.singleton (['a' .. 'z'] !! (ix `rem` 26))
      <> T.pack (show $ ix `quot` 26)

data GRule a = GRule
  { args :: NE.NonEmpty a,
    body :: Type0
  }
  deriving (Show)

type GRuleCall = Named (GRule Type2)

type GRuleDef = Named (GRule GRef)

callToDef :: GRule Type2 -> GRule GRef
callToDef gr = gr {args = refs}
  where
    refs =
      NE.unfoldr
        ( \ix ->
            ( freshName ix,
              if ix < NE.length gr.args - 1 then Just (ix + 1) else Nothing
            )
        )
        0

-- | Bind a single variable into a generic call
binding :: (IsType0 t0) => (GRef -> Rule) -> t0 -> GRuleCall
binding fRule t0 =
  Named
    rule.name
    GRule
      { args = NE.singleton t2,
        body = rule.value
      }
    Nothing
  where
    rule = fRule (freshName 0)
    t2 = case toType0 t0 of
      NoChoice x -> x
      _ -> error "Cannot use a choice of types as a generic argument"

-- | Bind two variables as a generic call
binding2 :: (IsType0 t0, IsType0 t1) => (GRef -> GRef -> Rule) -> t0 -> t1 -> GRuleCall
binding2 fRule t0 t1 =
  Named
    rule.name
    GRule
      { args = t02 NE.:| [t12],
        body = rule.value
      }
    Nothing
  where
    rule = fRule (freshName 0) (freshName 1)
    t02 = case toType0 t0 of
      NoChoice x -> x
      _ -> error "Cannot use a choice of types as a generic argument"
    t12 = case toType0 t1 of
      NoChoice x -> x
      _ -> error "Cannot use a choice of types as a generic argument"

--------------------------------------------------------------------------------
-- Collecting all top-level rules
--------------------------------------------------------------------------------

-- | Collect all rules starting from a given point.
collectFrom :: Rule -> Huddle
collectFrom topR =
  toHuddle $
    execState
      (goRule topR)
      (HaskMap.empty, HaskMap.empty, HaskMap.empty)
  where
    toHuddle (rules, groups, gRules) =
      Huddle
        { rules = NE.fromList $ view _2 <$> HaskMap.toList rules,
          groups = view _2 <$> HaskMap.toList groups,
          gRules = view _2 <$> HaskMap.toList gRules
        }
    goRule r@(Named n t0 _) = do
      (rules, _, _) <- get
      when (HaskMap.notMember n rules) $ do
        modify (over _1 $ HaskMap.insert n r)
        goT0 t0
    goChoice f (NoChoice x) = f x
    goChoice f (ChoiceOf x xs) = f x >> goChoice f xs
    goT0 = goChoice goT2
    goT2 (T2Map m) = goChoice (mapM_ goMapEntry . (.unMapChoice)) m
    goT2 (T2Array m) = goChoice (mapM_ goArrayEntry . (.unArrayChoice)) m
    goT2 (T2Tagged (Tagged _ t0)) = goT0 t0
    goT2 (T2Ref n) = goRule n
    goT2 (T2Group r@(Named n g _)) = do
      (_, groups, _) <- get
      when (HaskMap.notMember n groups) $ do
        modify (over _2 $ HaskMap.insert n r)
        goGroup g
    goT2 (T2Generic r@(Named n g _)) = do
      (_, _, gRules) <- get
      when (HaskMap.notMember n gRules) $ do
        modify (over _3 $ HaskMap.insert n (fmap callToDef r))
        goT0 g.body
    goT2 _ = pure ()
    goArrayEntry (ArrayEntry (Just k) t0 _) = goKey k >> goT0 t0
    goArrayEntry (ArrayEntry Nothing t0 _) = goT0 t0
    goMapEntry (MapEntry k t0 _) = goKey k >> goT0 t0
    goKey (TypeKey k) = goT2 k
    goKey _ = pure ()
    goGroup (Group g) = mapM_ goT0 g

--------------------------------------------------------------------------------
-- Conversion to CDDL
--------------------------------------------------------------------------------

-- | Convert from Huddle to CDDL for the purpose of pretty-printing.
toCDDL :: Huddle -> CDDL
toCDDL hdl =
  C.CDDL $
    fmap toCDDLRule hdl.rules
      `NE.appendList` fmap toCDDLGroup hdl.groups
      `NE.appendList` fmap toGenRuleDef hdl.gRules
  where
    toCDDLRule :: Rule -> C.WithComments C.Rule
    toCDDLRule (Named n t0 c) =
      C.WithComments
        ( C.Rule (C.Name n) Nothing C.AssignEq
            . C.TOGType
            . C.Type0
            $ toCDDLType1 <$> choiceToNE t0
        )
        (fmap C.Comment c)
    toCDDLValue :: Literal -> C.Value
    toCDDLValue (LInt i) = C.VNum $ fromIntegral i
    toCDDLValue (LText t) = C.VText t
    toCDDLValue (LBytes b) = C.VBytes b
    toCDDLValue _ = error "I haven't done this bit yet"

    mapToCDDLGroup :: Map -> C.Group
    mapToCDDLGroup xs = C.Group $ mapChoiceToCDDL <$> choiceToNE xs

    mapChoiceToCDDL :: MapChoice -> C.GrpChoice
    mapChoiceToCDDL (MapChoice entries) = fmap mapEntryToCDDL entries

    mapEntryToCDDL :: MapEntry -> C.GroupEntry
    mapEntryToCDDL (MapEntry k v occ) =
      C.GEType
        (toOccurrenceIndicator occ)
        (Just $ toMemberKey k)
        (toCDDLType0 v)

    toOccurrenceIndicator :: Occurs -> Maybe C.OccurrenceIndicator
    toOccurrenceIndicator (Occurs Nothing Nothing) = Nothing
    toOccurrenceIndicator (Occurs (Just 0) (Just 1)) = Just C.OIOptional
    toOccurrenceIndicator (Occurs (Just 0) Nothing) = Just C.OIZeroOrMore
    toOccurrenceIndicator (Occurs (Just 1) Nothing) = Just C.OIOneOrMore
    toOccurrenceIndicator (Occurs lb ub) = Just $ C.OIBounded lb ub

    toCDDLType1 :: Type2 -> C.Type1
    toCDDLType1 = \case
      T2Basic (Constrained x constr) ->
        -- TODO Need to handle choices at the top level
        constr.applyConstraint (C.T2Name (toCDDLPostlude x) Nothing)
      T2Literal l -> toCDDLRanged l
      T2Map m ->
        C.Type1
          (C.T2Map $ mapToCDDLGroup m)
          Nothing
      T2Array x -> C.Type1 (C.T2Array $ arrayToCDDLGroup x) Nothing
      T2Tagged (Tagged mmin x) ->
        C.Type1 (C.T2Tag mmin $ toCDDLType0 x) Nothing
      T2Ref (Named n _ _) -> C.Type1 (C.T2Name (C.Name n) Nothing) Nothing
      T2Group (Named n _ _) -> C.Type1 (C.T2Name (C.Name n) Nothing) Nothing
      T2Generic g -> C.Type1 (toGenericCall g) Nothing
      T2GenericRef (GRef n) -> C.Type1 (C.T2Name (C.Name n) Nothing) Nothing

    toMemberKey :: Key -> C.MemberKey
    toMemberKey (LiteralKey (LText t)) = C.MKBareword (C.Name t)
    toMemberKey (LiteralKey v) = C.MKValue $ toCDDLValue v
    toMemberKey (TypeKey t) = C.MKType (toCDDLType1 t)

    toCDDLType0 :: Type0 -> C.Type0
    toCDDLType0 = C.Type0 . fmap toCDDLType1 . choiceToNE

    arrayToCDDLGroup :: Array -> C.Group
    arrayToCDDLGroup xs = C.Group $ arrayChoiceToCDDL <$> choiceToNE xs

    arrayChoiceToCDDL :: ArrayChoice -> C.GrpChoice
    arrayChoiceToCDDL (ArrayChoice entries) = fmap arrayEntryToCDDL entries

    arrayEntryToCDDL :: ArrayEntry -> C.GroupEntry
    arrayEntryToCDDL (ArrayEntry k v occ) =
      C.GEType
        (toOccurrenceIndicator occ)
        (fmap toMemberKey k)
        (toCDDLType0 v)

    toCDDLPostlude :: Value a -> C.Name
    toCDDLPostlude VBool = C.Name "bool"
    toCDDLPostlude VUInt = C.Name "uint"
    toCDDLPostlude VNInt = C.Name "nint"
    toCDDLPostlude VInt = C.Name "int"
    toCDDLPostlude VHalf = C.Name "half"
    toCDDLPostlude VFloat = C.Name "float"
    toCDDLPostlude VDouble = C.Name "double"
    toCDDLPostlude VBytes = C.Name "bytes"
    toCDDLPostlude VText = C.Name "text"
    toCDDLPostlude VAny = C.Name "any"
    toCDDLPostlude VNil = C.Name "nil"

    toCDDLRanged :: Ranged -> C.Type1
    toCDDLRanged (Unranged x) =
      C.Type1 (C.T2Value $ toCDDLValue x) Nothing
    toCDDLRanged (Ranged lb ub rop) =
      C.Type1
        (C.T2Value $ toCDDLValue lb)
        (Just (C.RangeOp rop, C.T2Value $ toCDDLValue ub))

    toCDDLGroup :: Named Group -> C.WithComments C.Rule
    toCDDLGroup (Named n (Group t0s) c) =
      C.WithComments
        ( C.Rule (C.Name n) Nothing C.AssignEq
            . C.TOGGroup
            . C.GEGroup Nothing
            . C.Group
            . NE.singleton
            $ fmap (C.GEType Nothing Nothing . toCDDLType0) t0s
        )
        (fmap C.Comment c)

    toGenericCall :: GRuleCall -> C.Type2
    toGenericCall (Named n gr _) =
      C.T2Name
        (C.Name n)
        (Just . C.GenericArg $ fmap toCDDLType1 gr.args)

    toGenRuleDef :: GRuleDef -> C.WithComments C.Rule
    toGenRuleDef (Named n gr c) =
      C.WithComments
        ( C.Rule (C.Name n) (Just gps) C.AssignEq
            . C.TOGType
            . C.Type0
            $ toCDDLType1 <$> choiceToNE gr.body
        )
        (fmap C.Comment c)
      where
        gps =
          C.GenericParam $ fmap (\(GRef t) -> C.Name t) gr.args
