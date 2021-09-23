{-# OPTIONS_GHC -fno-warn-orphans #-}

module Hasura.Backends.BigQuery.Instances.Execute () where

import           Hasura.Prelude

import qualified Data.Aeson                       as Aeson
import qualified Data.HashMap.Strict.InsOrd       as OMap
import qualified Data.Text                        as T
import qualified Data.Text.Lazy                   as LT
import qualified Data.Text.Lazy.Builder           as LT
import qualified Data.Vector                      as V
import qualified Language.GraphQL.Draft.Syntax    as G

import qualified Hasura.Backends.BigQuery.Execute as DataLoader
import qualified Hasura.Backends.BigQuery.FromIr  as BigQuery
import qualified Hasura.Backends.BigQuery.ToQuery as ToQuery
import qualified Hasura.Backends.BigQuery.Types   as BigQuery
import qualified Hasura.Base.Error                as E
import qualified Hasura.SQL.AnyBackend            as AB
import qualified Hasura.Tracing                   as Tracing


import           Hasura.Backends.BigQuery.Plan
import           Hasura.Base.Error
import           Hasura.EncJSON
import           Hasura.GraphQL.Execute.Backend
import           Hasura.GraphQL.Parser
import           Hasura.RQL.IR
import           Hasura.RQL.Types
import           Hasura.Session


instance BackendExecute 'BigQuery where
  type PreparedQuery    'BigQuery = Text
  type MultiplexedQuery 'BigQuery = Void
  type ExecutionMonad   'BigQuery = Tracing.TraceT (ExceptT QErr IO)

  mkDBQueryPlan = bqDBQueryPlan
  mkDBMutationPlan = bqDBMutationPlan
  mkDBSubscriptionPlan _ _ _ _ =
    throw500 "Cannot currently perform subscriptions on BigQuery sources."
  mkDBQueryExplain = bqDBQueryExplain
  mkLiveQueryExplain _ =
    throw500 "Cannot currently retrieve query execution plans on BigQuery sources."

  -- NOTE: Currently unimplemented!.
  --
  -- This function is just a stub for future implementation; for now it just
  -- throws a 500 error.
  mkDBRemoteRelationshipPlan =
    bqDBRemoteRelationshipPlan


-- query

bqDBQueryPlan
  :: forall m.
     ( MonadError E.QErr m
     )
  => UserInfo
  -> SourceName
  -> SourceConfig 'BigQuery
  -> QueryDB 'BigQuery (Const Void) (UnpreparedValue 'BigQuery)
  -> m (DBStepInfo 'BigQuery)
bqDBQueryPlan userInfo sourceName sourceConfig qrf = do
  -- TODO (naveen): Append query tags to the query
  select <- planNoPlan (BigQuery.bigQuerySourceConfigToFromIrConfig sourceConfig) userInfo qrf
  let action = do
        result <-
          DataLoader.runExecute
            sourceConfig
            (DataLoader.executeSelect select)
        case result of
          Left err        -> throw500WithDetail "dataLoader error" $ Aeson.toJSON $ show err
          Right recordSet -> pure $! recordSetToEncJSON (BigQuery.selectCardinality select) recordSet
  pure $ DBStepInfo @'BigQuery sourceName sourceConfig (Just (selectSQLTextForExplain select)) action

-- | Convert the dataloader's 'RecordSet' type to JSON.
recordSetToEncJSON :: BigQuery.Cardinality -> DataLoader.RecordSet -> EncJSON
recordSetToEncJSON cardinality DataLoader.RecordSet {rows} =
  case cardinality of
    BigQuery.One
      | Just row <- rows V.!? 0 -> encJFromRecord row
      | otherwise -> encJFromList (toList (fmap encJFromRecord rows))
    BigQuery.Many -> encJFromList (toList (fmap encJFromRecord rows))
  where
    encJFromRecord =
      encJFromInsOrdHashMap . fmap encJFromOutputValue . OMap.mapKeys coerce
    encJFromOutputValue outputValue =
      case outputValue of
        DataLoader.NullOutputValue -> encJFromJValue Aeson.Null
        DataLoader.DecimalOutputValue !i -> encJFromJValue i
        DataLoader.BigDecimalOutputValue !i -> encJFromJValue i
        DataLoader.FloatOutputValue !i -> encJFromJValue i
        DataLoader.TextOutputValue !i -> encJFromJValue i
        DataLoader.BytesOutputValue !i -> encJFromJValue i
        DataLoader.DateOutputValue !i -> encJFromJValue i
        DataLoader.TimestampOutputValue !i -> encJFromJValue i
        DataLoader.TimeOutputValue !i -> encJFromJValue i
        DataLoader.DatetimeOutputValue !i -> encJFromJValue i
        DataLoader.GeographyOutputValue !i -> encJFromJValue i
        DataLoader.BoolOutputValue !i -> encJFromJValue i
        DataLoader.IntegerOutputValue !i -> encJFromJValue i
        DataLoader.ArrayOutputValue !vector ->
          encJFromList (toList (fmap encJFromOutputValue vector))
        -- Really, the case below shouldn't be happening. But if it
        -- does, it's not a problem either. The output will just have
        -- a record in it.
        DataLoader.RecordOutputValue !record -> encJFromRecord record


-- mutation

bqDBMutationPlan
  :: forall m.
     ( MonadError E.QErr m
     )
  => UserInfo
  -> Bool
  -> SourceName
  -> SourceConfig 'BigQuery
  -> MutationDB 'BigQuery (Const Void) (UnpreparedValue 'BigQuery)
  -> m (DBStepInfo 'BigQuery)
bqDBMutationPlan _userInfo _stringifyNum _sourceName _sourceConfig _mrf =
  throw500 "mutations are not supported in BigQuery; this should be unreachable"


-- explain

bqDBQueryExplain
  :: MonadError E.QErr m
  => G.Name
  -> UserInfo
  -> SourceName
  -> SourceConfig 'BigQuery
  -> QueryDB 'BigQuery (Const Void) (UnpreparedValue 'BigQuery)
  -> m (AB.AnyBackend DBStepInfo)
bqDBQueryExplain fieldName userInfo sourceName sourceConfig qrf = do
  select <- planNoPlan (BigQuery.bigQuerySourceConfigToFromIrConfig sourceConfig) userInfo qrf
  let textSQL = selectSQLTextForExplain select
  pure
    $ AB.mkAnyBackend
    $ DBStepInfo @'BigQuery sourceName sourceConfig Nothing
    $ pure
    $ encJFromJValue
    $ ExplainPlan
        fieldName
        (Just $ textSQL)
        (Just $ T.lines $ textSQL)

-- | Get the SQL text for a select, with parameters left as $1, $2, .. holes.
selectSQLTextForExplain :: BigQuery.Select -> Text
selectSQLTextForExplain =
  LT.toStrict .
  LT.toLazyText . fst . ToQuery.renderBuilderPretty . ToQuery.fromSelect

--------------------------------------------------------------------------------
-- Remote Relationships (e.g. DB-to-DB Joins, remote schema joins, etc.)
--------------------------------------------------------------------------------

-- | Construct an action (i.e. 'DBStepInfo') which can marshal some remote
-- relationship information into a form that BigQuery can query against.
--
-- XXX: Currently unimplemented; the Postgres implementation uses
-- @jsonb_to_recordset@ to query the remote relationship, however this
-- functionality doesn't exist in BigQuery.
--
-- NOTE: The following typeclass constraints will be necessary when implementing
-- this function for real:
--
-- @
--   MonadQueryTags m
--   Backend 'BigQuery
-- @
bqDBRemoteRelationshipPlan
  :: forall m
   . ( MonadError QErr m
     )
  => UserInfo
  -> SourceName
  -> SourceConfig 'BigQuery
  -- | List of json objects, each of which becomes a row of the table.
  -> NonEmpty Aeson.Object
  -- | The above objects have this schema
  --
  -- XXX: What is this for/what does this mean?
  -> HashMap FieldName (Column 'BigQuery, ScalarType 'BigQuery)
  -- | This is a field name from the lhs that *has* to be selected in the
  -- response along with the relationship.
  -> FieldName
  -> (FieldName, SourceRelationshipSelection 'BigQuery (Const Void) UnpreparedValue)
  -> m (DBStepInfo 'BigQuery)
bqDBRemoteRelationshipPlan _userInfo _sourceName _sourceConfig _lhs _lhsSchema _argumentId _relationship = do
  throw500 "mkDBRemoteRelationshipPlan: BigQuery does not currently support generalized joins."
