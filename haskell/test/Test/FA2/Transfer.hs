-- SPDX-FileCopyrightText: 2021 Arthur Breitman
-- SPDX-License-Identifier: LicenseRef-MIT-Arthur-Breitman

module Test.FA2.Transfer
  ( test_zero_transfers
  , test_unknown_position
  , test_removed_position
  , test_getting_position_back
  , test_not_owner
  , test_not_operator
  , test_fungible_amount
  , test_owner_transfer
  , test_operator_transfer
  , test_self_transfer
  , test_multiple_transfers
  ) where
import Universum

import Test.Tasty (TestTree)

import qualified Lorentz.Contracts.Spec.FA2Interface as FA2
import Lorentz.Macro
import Lorentz.Test (contractConsumer)
import Morley.Nettest
import Morley.Nettest.Tasty
import Util.Named

import SegCFMM.Types
import Test.Util

test_zero_transfers :: TestTree
test_zero_transfers =
  forAllTokenTypeCombinations "transfer is always accepted when the amount is 0" \tokenTypes ->
  nettestScenarioOnEmulatorCaps (show tokenTypes) do
    owner <- newAddress auto
    operator <- newAddress auto
    cfmm <- fst <$> prepareSomeSegCFMM [owner] tokenTypes def

    -- the token does not even exist
    withSender owner do
      transferToken cfmm owner operator (FA2.TokenId 0) 0

      setPosition cfmm 1_e7 (-10, 15)
      transferToken cfmm owner operator (FA2.TokenId 0) 0

      setPosition cfmm 1_e7 (-20, -15)
      updateOperator cfmm owner operator (FA2.TokenId 1) True

    withSender operator $ transferToken cfmm owner operator (FA2.TokenId 1) 0

test_unknown_position :: TestTree
test_unknown_position =
  forAllTokenTypeCombinations "transfer does not accept unknown positions" \tokenTypes ->
  nettestScenarioOnEmulatorCaps (show tokenTypes) do
    owner <- newAddress auto
    receiver <- newAddress auto
    cfmm <- fst <$> prepareSomeSegCFMM [owner] tokenTypes def

    expectCustomError_ #fA2_TOKEN_UNDEFINED $
      withSender owner $ transferToken' cfmm owner receiver (FA2.TokenId 0)

test_removed_position :: TestTree
test_removed_position =
  forAllTokenTypeCombinations "depositing and withdrawing the same amount of liquidity is a no-op" $ \tokenTypes ->
  nettestScenarioOnEmulatorCaps (show tokenTypes) do
    let liquidityDelta = 10000000
    let lowerTickIndex = -10
    let upperTickIndex = 15

    owner <- newAddress auto
    receiver <- newAddress auto
    cfmm <- fst <$> prepareSomeSegCFMM [owner] tokenTypes def

    withSender owner do
      setPosition cfmm liquidityDelta (lowerTickIndex, upperTickIndex)
      updatePosition cfmm owner (- toInteger liquidityDelta) 0

      -- the token is once again undefined because the position was removed
      expectCustomError_ #fA2_TOKEN_UNDEFINED $
        transferToken' cfmm owner receiver (FA2.TokenId 0)

test_getting_position_back :: TestTree
test_getting_position_back =
  forAllTokenTypeCombinations "transferring position, creating a similar one and transferring the old one back is fine" \tokenTypes ->
  nettestScenarioOnEmulatorCaps (show tokenTypes) do
    let lowerTickIndex = -10
    let upperTickIndex = 10

    owner <- newAddress auto
    foreigner <- newAddress "foreigner"
    cfmm <- fst <$> prepareSomeSegCFMM [owner] tokenTypes def

    withSender owner do
      setPosition cfmm 1000 (lowerTickIndex, upperTickIndex)
      transferToken' cfmm owner foreigner (FA2.TokenId 0)
      setPosition cfmm 5 (lowerTickIndex, upperTickIndex)
    withSender foreigner do
      transferToken' cfmm foreigner owner (FA2.TokenId 0)

    consumer <- originateSimple "consumer" [] contractConsumer
    mapM_ (call cfmm (Call @"Get_position_info") . flip mkView consumer . PositionId) [0, 1]
    (getFullStorage consumer <&> fmap piLiquidity <&> reverse) @@== [1000, 5]


test_not_owner :: TestTree
test_not_owner =
  forAllTokenTypeCombinations "transfer rejects non-owned/operated positions" \tokenTypes ->
  nettestScenarioOnEmulatorCaps (show tokenTypes) do
    owner <- newAddress auto
    notOwner <- newAddress auto
    receiver <- newAddress auto
    cfmm <- fst <$> prepareSomeSegCFMM [owner, notOwner, receiver] tokenTypes def

    withSender owner $ setPosition cfmm 1_e7 (-10, 15)
    expectCustomError #fA2_INSUFFICIENT_BALANCE (#required .! 1, #present .! 0) $
      withSender notOwner $ transferToken' cfmm notOwner receiver (FA2.TokenId 0)

test_not_operator :: TestTree
test_not_operator =
  forAllTokenTypeCombinations "transfer rejects invalid operators" \tokenTypes ->
  nettestScenarioOnEmulatorCaps (show tokenTypes) do
    owner <- newAddress auto
    notOper <- newAddress auto
    cfmm <- fst <$> prepareSomeSegCFMM [owner, notOper] tokenTypes def

    withSender owner $ setPosition cfmm 1_e7 (-10, 15)
    expectCustomError_ #fA2_NOT_OPERATOR $
      withSender notOper $ transferToken' cfmm owner notOper (FA2.TokenId 0)

test_fungible_amount :: TestTree
test_fungible_amount =
  forAllTokenTypeCombinations "transfer rejects amounts higher than 1" \tokenTypes ->
  nettestScenarioOnEmulatorCaps (show tokenTypes) do
    owner <- newAddress auto
    receiver <- newAddress auto
    cfmm <- fst <$> prepareSomeSegCFMM [owner] tokenTypes def

    withSender owner do
      setPosition cfmm 1_e7 (-10, 15)
      expectCustomError #fA2_INSUFFICIENT_BALANCE (#required .! 2, #present .! 1) $
        transferToken cfmm owner receiver (FA2.TokenId 0) 2

test_owner_transfer :: TestTree
test_owner_transfer =
  forAllTokenTypeCombinations "transfer moves positions when called by owner" \tokenTypes ->
  nettestScenarioOnEmulatorCaps (show tokenTypes) do
    owner <- newAddress auto
    receiver <- newAddress auto
    cfmm <- fst <$> prepareSomeSegCFMM [owner] tokenTypes def

    withSender owner do
      setPosition cfmm 1_e7 (-10, 15)
      balanceOf (TokenInfo (FA2.TokenId 0) cfmm) owner @@== 1
      balanceOf (TokenInfo (FA2.TokenId 0) cfmm) receiver @@== 0
      transferToken' cfmm owner receiver (FA2.TokenId 0)
      balanceOf (TokenInfo (FA2.TokenId 0) cfmm) owner @@== 0
      balanceOf (TokenInfo (FA2.TokenId 0) cfmm) receiver @@== 1
      -- check that previous owner can no longer manage the position ...
      expectCustomError #fA2_INSUFFICIENT_BALANCE (#required .! 1, #present .! 0) $
        transferToken' cfmm owner receiver (FA2.TokenId 0)
    -- ... but the new one can
    withSender receiver $ transferToken' cfmm receiver owner (FA2.TokenId 0)

test_operator_transfer :: TestTree
test_operator_transfer =
  forAllTokenTypeCombinations "transfer moves positions when called by operator" \tokenTypes ->
  nettestScenarioOnEmulatorCaps (show tokenTypes) do
    owner <- newAddress auto
    operator <- newAddress auto
    receiver <- newAddress auto
    cfmm <- fst <$> prepareSomeSegCFMM [owner] tokenTypes def

    withSender owner do
      setPosition cfmm 1_e7 (-10, 15)
      updateOperator cfmm owner operator (FA2.TokenId 0) True

    balanceOf (TokenInfo (FA2.TokenId 0) cfmm) owner @@== 1
    balanceOf (TokenInfo (FA2.TokenId 0) cfmm) operator @@== 0
    balanceOf (TokenInfo (FA2.TokenId 0) cfmm) receiver @@== 0
    withSender operator $ transferToken' cfmm owner receiver (FA2.TokenId 0)
    balanceOf (TokenInfo (FA2.TokenId 0) cfmm) owner @@== 0
    balanceOf (TokenInfo (FA2.TokenId 0) cfmm) operator @@== 0
    balanceOf (TokenInfo (FA2.TokenId 0) cfmm) receiver @@== 1

test_self_transfer :: TestTree
test_self_transfer =
  forAllTokenTypeCombinations "transfer accepts self-transfer of an existing position" \tokenTypes ->
  nettestScenarioOnEmulatorCaps (show tokenTypes) do
    owner <- newAddress auto
    cfmm <- fst <$> prepareSomeSegCFMM [owner] tokenTypes def

    withSender owner do
      setPosition cfmm 1_e7 (-10, 15)
      transferToken' cfmm owner owner (FA2.TokenId 0)

test_multiple_transfers :: TestTree
test_multiple_transfers =
  forAllTokenTypeCombinations "transfer can handle multiple updates, in order" \tokenTypes ->
  nettestScenarioOnEmulatorCaps (show tokenTypes) do
    owner1 <- newAddress auto
    owner2 <- newAddress auto
    receiver <- newAddress auto
    cfmm <- fst <$> prepareSomeSegCFMM [owner1, owner2, receiver] tokenTypes def

    withSender owner1 do
      setPosition cfmm 1_e7 (-10, 15)
      setPosition cfmm 1_e7 (-20, -15)
    withSender owner2 do
      setPosition cfmm 1_e7 (5, 12)
      updateOperator cfmm owner2 owner1 (FA2.TokenId 2) True
    let tokenIds = map FA2.TokenId [0..2]

    balancesOf cfmm tokenIds owner1    @@== [1, 1, 0]
    balancesOf cfmm tokenIds owner2    @@== [0, 0, 1]
    balancesOf cfmm tokenIds receiver  @@== [0, 0, 0]

    withSender owner1 $ transferTokens cfmm
      [ FA2.TransferItem owner2
          [ FA2.TransferDestination owner1 (FA2.TokenId 2) 1 ]
      , FA2.TransferItem owner1 $
          [ FA2.TransferDestination receiver (FA2.TokenId 0) 1
          , FA2.TransferDestination owner2 (FA2.TokenId 1) 1
          , FA2.TransferDestination receiver (FA2.TokenId 2) 1
          ]
      ]

    balancesOf cfmm tokenIds owner1    @@== [0, 0, 0]
    balancesOf cfmm tokenIds owner2    @@== [0, 1, 0]
    balancesOf cfmm tokenIds receiver  @@== [1, 0, 1]
