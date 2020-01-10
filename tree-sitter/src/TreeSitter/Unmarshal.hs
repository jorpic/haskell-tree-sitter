{-# LANGUAGE DefaultSignatures   #-}
{-# LANGUAGE DeriveFunctor       #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE FlexibleInstances   #-}
{-# LANGUAGE PolyKinds           #-}
{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications    #-}
{-# LANGUAGE TypeOperators       #-}
{-# LANGUAGE TupleSections       #-}

module TreeSitter.Unmarshal
( parseByteString
, UnmarshalState(..)
, UnmarshalError(..)
, FieldName(..)
, Unmarshal(..)
, UnmarshalAnn(..)
, UnmarshalField(..)
, SymbolMatching(..)
, Match(..)
, hoist
, lookupSymbol
, unmarshal
, unmarshalNode
, peekNode
) where

import           Control.Algebra (send)
import           Control.Carrier.Reader hiding (asks)
import           Control.Exception
import           Control.Monad ((<=<))
import           Control.Monad.IO.Class
import           Data.ByteString (ByteString)
import qualified Data.ByteString as B
import           Data.Coerce
import           Data.Foldable (toList)
import qualified Data.IntMap as IntMap
import qualified Data.Text as Text
import           Data.Text.Encoding
import           Data.Text.Encoding.Error (lenientDecode)
import           Foreign.C.String
import           Foreign.Marshal.Alloc
import           Foreign.Marshal.Utils
import           Foreign.Ptr
import           Foreign.Storable
import           GHC.Generics
import           GHC.TypeLits
import           TreeSitter.Cursor as TS
import           TreeSitter.Language as TS
import           TreeSitter.Node as TS
import           TreeSitter.Parser as TS
import           TreeSitter.Tree as TS
import           TreeSitter.Token as TS
import           Source.Loc
import           Source.Span
import           Data.Proxy
import           Data.List.NonEmpty (NonEmpty (..))

asks :: Has (Reader r) sig m => (r -> r') -> m r'
asks f = send (Ask (pure . f))
{-# INLINE asks #-}

-- Parse source code and produce AST
parseByteString :: (Unmarshal t, UnmarshalAnn a) => Ptr TS.Language -> ByteString -> IO (Either String (t a))
parseByteString language bytestring = withParser language $ \ parser -> withParseTree parser bytestring $ \ treePtr ->
  if treePtr == nullPtr then
    pure (Left "error: didn't get a root node")
  else
    withRootNode treePtr $ \ rootPtr ->
      withCursor (castPtr rootPtr) $ \ cursor ->
        (Right <$> runReader (UnmarshalState bytestring cursor) (unmarshal cursor))
          `catch` (pure . Left . getUnmarshalError)

newtype UnmarshalError = UnmarshalError { getUnmarshalError :: String }
  deriving (Show)

instance Exception UnmarshalError

data UnmarshalState = UnmarshalState
  { source :: {-# UNPACK #-} !ByteString
  , cursor :: {-# UNPACK #-} !(Ptr Cursor)
  }

type MatchM = ReaderC UnmarshalState IO

newtype Match t = Match
  { runMatch :: forall a . UnmarshalAnn a => Node -> MatchM (t a)
  }

newtype B a = B (forall r . (r -> r -> r) -> (a -> r) -> r -> r)

instance Functor B where
  fmap f (B run) = B (\ fork leaf -> run fork (leaf . f))
  {-# INLINE fmap #-}
  a <$ B run = B (\ fork leaf -> run fork (leaf . const a))
  {-# INLINE (<$) #-}

instance Semigroup (B a) where
  B l <> B r = B (\ fork leaf nil -> fork (l fork leaf nil) (r fork leaf nil))
  {-# INLINE (<>) #-}

instance Monoid (B a) where
  mempty = B (\ _ _ nil -> nil)
  {-# INLINE mempty #-}

instance Foldable B where
  foldMap f (B run) = run (<>) f mempty
  {-# INLINE foldMap #-}

singleton :: a -> B a
singleton a = B (\ _ leaf _ -> leaf a)
{-# INLINE singleton #-}

hoist :: (forall x . t x -> t' x) -> Match t -> Match t'
hoist f (Match run) = Match (fmap f . run)
{-# INLINE hoist #-}

lookupSymbol :: TSSymbol -> IntMap.IntMap a -> Maybe a
lookupSymbol sym map = IntMap.lookup (fromIntegral sym) map
{-# INLINE lookupSymbol #-}

unmarshal :: (UnmarshalAnn a, Unmarshal t) => Ptr Cursor -> MatchM (t a)
unmarshal = unmarshalNode <=< peekNode
{-# INLINE unmarshal #-}

-- | Unmarshal a node
unmarshalNode :: forall t a .
                 ( UnmarshalAnn a
                 , Unmarshal t
                 )
  => Node
  -> MatchM (t a)
unmarshalNode node = case lookupSymbol (nodeSymbol node) matchers' of
  Just t -> runMatch t node
  Nothing -> liftIO . throwIO . UnmarshalError $ showFailure (Proxy @t) node
{-# INLINE unmarshalNode #-}

-- | Unmarshalling is the process of iterating over tree-sitter’s parse trees using its tree cursor API and producing Haskell ASTs for the relevant nodes.
--
--   Datatypes which can be constructed from tree-sitter parse trees may use the default definition of 'matchers' providing that they have a suitable 'Generic1' instance.
class SymbolMatching t => Unmarshal t where
  matchers' :: IntMap.IntMap (Match t)
  matchers' = IntMap.fromList (toList matchers)

  matchers :: B (Int, Match t)
  default matchers :: (Generic1 t, GUnmarshal (Rep1 t)) => B (Int, Match t)
  matchers = foldMap (singleton . (, match)) (matchedSymbols (Proxy @t))
    where match = Match $ \ node -> do
            cursor <- asks cursor
            goto cursor (nodeTSNode node)
            fmap to1 (gunmarshalNode node)

instance (Unmarshal f, Unmarshal g) => Unmarshal (f :+: g) where
  matchers = fmap (fmap (hoist L1)) matchers <> fmap (fmap (hoist R1)) matchers

instance Unmarshal t => Unmarshal (Rec1 t) where
  matchers = fmap (fmap (hoist Rec1)) matchers

instance (KnownNat n, KnownSymbol sym) => Unmarshal (Token sym n) where
  matchers = singleton (fromIntegral (natVal (Proxy @n)), Match (fmap Token . unmarshalAnn))


-- | Unmarshal an annotation field.
--
--   Leaf nodes have 'Text.Text' fields, and leaves, anonymous leaves, and products all have parametric annotation fields. All of these fields are unmarshalled using the metadata of the node, e.g. its start/end bytes, without reference to any child nodes it may contain.
class UnmarshalAnn a where
  unmarshalAnn
    :: Node
    -> MatchM a

instance UnmarshalAnn () where
  unmarshalAnn _ = pure ()

instance UnmarshalAnn Text.Text where
  unmarshalAnn node = do
    range <- unmarshalAnn node
    asks (decodeUtf8With lenientDecode . slice range . source)

-- | Instance for pairs of annotations
instance (UnmarshalAnn a, UnmarshalAnn b) => UnmarshalAnn (a,b) where
  unmarshalAnn node = (,)
    <$> unmarshalAnn @a node
    <*> unmarshalAnn @b node

instance UnmarshalAnn Loc where
  unmarshalAnn node = Loc
    <$> unmarshalAnn @Range node
    <*> unmarshalAnn @Span  node

instance UnmarshalAnn Range where
  unmarshalAnn node = do
    let start = fromIntegral (nodeStartByte node)
        end   = fromIntegral (nodeEndByte node)
    pure (Range start end)

instance UnmarshalAnn Span where
  unmarshalAnn node = do
    let spanStart = pointToPos (nodeStartPoint node)
        spanEnd   = pointToPos (nodeEndPoint node)
    pure (Span spanStart spanEnd)

pointToPos :: TSPoint -> Pos
pointToPos (TSPoint line column) = Pos (fromIntegral line) (fromIntegral column)


-- | Optional/repeated fields occurring in product datatypes are wrapped in type constructors, e.g. 'Maybe', '[]', or 'NonEmpty', and thus can unmarshal zero or more nodes for the same field name.
class UnmarshalField t where
  unmarshalField
    :: ( Unmarshal f
       , UnmarshalAnn a
       )
    => String -- ^ datatype name
    -> String -- ^ field name
    -> [Node] -- ^ nodes
    -> MatchM (t (f a))

instance UnmarshalField Maybe where
  unmarshalField _ _ []  = pure Nothing
  unmarshalField _ _ [x] = Just <$> unmarshalNode x
  unmarshalField d f _   = liftIO . throwIO . UnmarshalError $ "type '" <> d <> "' expected zero or one nodes in field '" <> f <> "' but got multiple"

instance UnmarshalField [] where
  unmarshalField d f (x:xs) = do
    head' <- unmarshalNode x
    tail' <- unmarshalField d f xs
    pure $ head' : tail'
  unmarshalField _ _ [] = pure []

instance UnmarshalField NonEmpty where
  unmarshalField d f (x:xs) = do
    head' <- unmarshalNode x
    tail' <- unmarshalField d f xs
    pure $ head' :| tail'
  unmarshalField d f [] = liftIO . throwIO . UnmarshalError $ "type '" <> d <> "' expected one or more nodes in field '" <> f <> "' but got zero"

class SymbolMatching (a :: * -> *) where
  matchedSymbols :: Proxy a -> [Int]

  -- | Provide error message describing the node symbol vs. the symbols this can match
  showFailure :: Proxy a -> Node -> String

instance SymbolMatching f => SymbolMatching (M1 i c f) where
  matchedSymbols _ = matchedSymbols (Proxy @f)
  showFailure _ = showFailure (Proxy @f)

instance SymbolMatching f => SymbolMatching (Rec1 f) where
  matchedSymbols _ = matchedSymbols (Proxy @f)
  showFailure _ = showFailure (Proxy @f)

instance (KnownNat n, KnownSymbol sym) => SymbolMatching (Token sym n) where
  matchedSymbols _ = [fromIntegral (natVal (Proxy @n))]
  showFailure _ _ = "expected " ++ symbolVal (Proxy @sym)

instance (SymbolMatching f, SymbolMatching g) => SymbolMatching (f :+: g) where
  matchedSymbols _ = matchedSymbols (Proxy @f) <> matchedSymbols (Proxy @g)
  showFailure _ = sep <$> showFailure (Proxy @f) <*> showFailure (Proxy @g)

sep :: String -> String -> String
sep a b = a ++ ". " ++ b

-- | Advance the cursor to the next sibling of the current node.
step :: Ptr Cursor -> MatchM Bool
step = liftIO . ts_tree_cursor_goto_next_sibling

-- | Move the cursor to point at the passed 'TSNode'.
goto :: Ptr Cursor -> TSNode -> MatchM ()
goto cursor node = liftIO (with node (ts_tree_cursor_reset_p cursor))

-- | Return the 'Node' that the cursor is pointing at.
peekNode :: Ptr Cursor -> MatchM Node
peekNode cursor =
  liftIO $ alloca $ \ tsNodePtr -> do
    _ <- ts_tree_cursor_current_node_p cursor tsNodePtr
    alloca $ \ nodePtr -> do
      ts_node_poke_p tsNodePtr nodePtr
      peek nodePtr

-- | Return the field name (if any) for the node that the cursor is pointing at (if any), or 'Nothing' otherwise.
peekFieldName :: Ptr Cursor -> MatchM (Maybe FieldName)
peekFieldName cursor = do
  fieldName <- liftIO $ ts_tree_cursor_current_field_name cursor
  if fieldName == nullPtr then
    pure Nothing
  else
    Just . FieldName . toHaskellCamelCaseIdentifier <$> liftIO (peekCString fieldName)


-- | Return a 'ByteString' that contains a slice of the given 'ByteString'.
slice :: Range -> ByteString -> ByteString
slice (Range start end) = take . drop
  where drop = B.drop start
        take = B.take (end - start)


newtype FieldName = FieldName { getFieldName :: String }
  deriving (Eq, Ord, Show)

-- | Generic construction of ASTs from a 'Map.Map' of named fields.
--
--   Product types (specifically, record types) are constructed by looking up the node for each corresponding field name in the map, moving the cursor to it, and then invoking 'unmarshalNode' to construct the value for that field. Leaf types are constructed as a special case of product types.
--
--   Sum types are constructed by using the current node’s symbol to select the corresponding constructor deterministically.
class GUnmarshal f where
  gunmarshalNode
    :: UnmarshalAnn a
    => Node
    -> MatchM (f a)

instance (Datatype d, GUnmarshalData f) => GUnmarshal (M1 D d f) where
  gunmarshalNode = go (gunmarshalNode' (datatypeName @d undefined)) where
    go :: (Node -> MatchM (f a)) -> Node -> MatchM (M1 i c f a)
    go = coerce

class GUnmarshalData f where
  gunmarshalNode'
    :: UnmarshalAnn a
    => String
    -> Node
    -> MatchM (f a)

instance GUnmarshalData f => GUnmarshalData (M1 i c f) where
  gunmarshalNode' = go gunmarshalNode' where
    go :: (String -> Node -> MatchM (f a)) -> String -> Node -> MatchM (M1 i c f a)
    go = coerce

-- For anonymous leaf nodes:
instance GUnmarshalData U1 where
  gunmarshalNode' _ _ = pure U1

-- For unary products:
instance UnmarshalAnn k => GUnmarshalData (K1 c k) where
  gunmarshalNode' _ = go unmarshalAnn where
    go :: (Node -> MatchM k) -> Node -> MatchM (K1 c k a)
    go = coerce

-- For anonymous leaf nodes
instance GUnmarshalData Par1 where
  gunmarshalNode' _ = go unmarshalAnn where
    go :: (Node -> MatchM a) -> Node -> MatchM (Par1 a)
    go = coerce

instance Unmarshal t => GUnmarshalData (Rec1 t) where
  gunmarshalNode' _ = go unmarshalNode where
    go :: (Node -> MatchM (t a)) -> Node -> MatchM (Rec1 t a)
    go = coerce

-- For product datatypes:
instance (GUnmarshalProduct f, GUnmarshalProduct g) => GUnmarshalData (f :*: g) where
  gunmarshalNode' = gunmarshalProductNode @(f :*: g)


-- | Generically unmarshal products
class GUnmarshalProduct f where
  gunmarshalProductNode
    :: UnmarshalAnn a
    => String
    -> Node
    -> MatchM (f a)

-- Product structure
instance (GUnmarshalProduct f, GUnmarshalProduct g) => GUnmarshalProduct (f :*: g) where
  gunmarshalProductNode datatypeName node = (:*:)
    <$> gunmarshalProductNode @f datatypeName node
    <*> gunmarshalProductNode @g datatypeName node

-- Contents of product types (ie., the leaves of the product tree)
instance UnmarshalAnn k => GUnmarshalProduct (M1 S c (K1 i k)) where
  gunmarshalProductNode _ = go unmarshalAnn where
    go :: (Node -> MatchM k) -> Node -> MatchM (M1 S c (K1 i k) a)
    go = coerce

instance GUnmarshalProduct (M1 S c Par1) where
  gunmarshalProductNode _ = go unmarshalAnn where
    go :: (Node -> MatchM a) -> Node -> MatchM (M1 S c Par1 a)
    go = coerce

instance (UnmarshalField f, Unmarshal g, Selector c) => GUnmarshalProduct (M1 S c (f :.: g)) where
  gunmarshalProductNode datatypeName node = do
    cursor <- asks cursor
    liftIO (with (nodeTSNode node) (ts_tree_cursor_reset_p cursor))
    let fieldName = selName @c undefined
    nodes <- nodesForField cursor (FieldName fieldName)
    go (unmarshalField datatypeName fieldName) nodes where
    go :: ([Node] -> MatchM (f (g a))) -> [Node] -> MatchM (M1 S c (f :.: g) a)
    go = coerce

instance (Unmarshal t, Selector c) => GUnmarshalProduct (M1 S c (Rec1 t)) where
  gunmarshalProductNode datatypeName node = do
    cursor <- asks cursor
    liftIO (with (nodeTSNode node) (ts_tree_cursor_reset_p cursor))
    nodes <- nodesForField cursor (FieldName (selName @c undefined))
    case nodes of
      []  -> liftIO . throwIO . UnmarshalError $ "type '" <> datatypeName <> "' expected a node '" <> selName @c undefined <> "' but didn't get one"
      [x] -> go unmarshalNode x where
        go :: (Node -> MatchM (t a)) -> Node -> MatchM (M1 S c (Rec1 t) a)
        go = coerce
      _   -> liftIO . throwIO . UnmarshalError $ "type '" <> datatypeName <> "' expected a node but got multiple"


nodesForField :: Ptr Cursor -> FieldName -> MatchM [Node]
nodesForField cursor name = do
  hasChildren <- liftIO (ts_tree_cursor_goto_first_child cursor)
  if hasChildren then
    go id
  else
    pure [] where
  go nodes = do
    -- FIXME: we’re copying every node, even the ones we don’t use
    node <- peekNode cursor
    fieldName <- peekFieldName cursor
    keepGoing <- step cursor
    let nodes'
          | Just fieldName' <- fieldName
          , fieldName' == name    = nodes . (node:)
          -- NB: We currently skip “extra” nodes (i.e. ones occurring in the @extras@ rule), pending a fix to https://github.com/tree-sitter/haskell-tree-sitter/issues/99
          | name == FieldName "extraChildren"
          , nodeIsNamed node /= 0
          , nodeIsExtra node == 0 = nodes . (node:)
          | otherwise             = nodes
    if keepGoing then
      go nodes'
    else
      nodes' [] <$ liftIO (ts_tree_cursor_goto_parent cursor)
