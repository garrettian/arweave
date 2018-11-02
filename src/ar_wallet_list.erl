-module(ar_wallet_list).
-export([
	apply_mining_reward/4,
	apply_txs/2, apply_tx/2,
	apply_txs_then_mining_reward/5,
	calculate_tx_gen_fee/2,
	check_address_last_tx/3,
	filter_all_out_of_order_txs/2,
	filter_out_of_order_txs/2, filter_out_of_order_txs/3,
	hash/1,
	validate/1
	]).

-include("ar.hrl").

%% @doc Calculate and apply mining reward quantities to a wallet list.
apply_mining_reward(WalletList, unclaimed, _Quantity, _Height) ->
	WalletList;
apply_mining_reward(WalletList, RewardAddr, Quantity, Height) ->
	alter_wallet(WalletList, RewardAddr, ar_node_utils:calculate_reward(Height, Quantity)).

%% @doc Update a wallet list with a set of new transactions.
apply_txs(WalletList, TXs) ->
	lists:sort(
		lists:foldl(
			fun(TX, CurrWalletList) ->
				apply_tx(CurrWalletList, TX)
			end,
			WalletList,
			TXs
		)
	).

apply_txs_then_mining_reward(WalletList, TXs, RewardAddr, Quantity, Height) ->
	apply_mining_reward(
		apply_txs(WalletList, TXs),
		RewardAddr,
		Quantity,
		Height
	).

%% @doc Apply a transaction to a wallet list, updating it.
%% Critically, filter empty wallets from the list after application.
apply_tx(WalletList, unavailable) -> WalletList;
apply_tx(WalletList, TX) ->	do_apply_tx(WalletList, TX).

%% @doc Calculate base tx generation fee for a wallet list.
%% called from ar_tx
calculate_tx_gen_fee(_, undefined) -> 0;
calculate_tx_gen_fee(_, <<>>) -> 0;
calculate_tx_gen_fee(WalletList, Address) ->
	case lists:keymember(Address, 1, WalletList) of
		true  -> 0;
		false -> ?WALLET_GEN_FEE
    end.

%% @doc Check if wallet list contains a {Address, _, LastTX} wallet.
%% if so return true else false.
check_address_last_tx(WalletList, Address, LastTX) ->
	case lists:keyfind(Address, 1, WalletList) of
		{Address, _, LastTX} -> true;
		_ -> false
	end.

%% @doc Takes a wallet list and a set of txs and checks to ensure that the
%% txs can be applied in a given order. The output is the set of all txs
%% that could be applied.
filter_all_out_of_order_txs(WalletList, InTXs) ->
	filter_all_out_of_order_txs(WalletList, InTXs, []).

filter_all_out_of_order_txs(_WalletList, [], OutTXs) ->
	lists:reverse(OutTXs);
filter_all_out_of_order_txs(WalletList, InTXs, OutTXs) ->
	{FloatingWalletList, PassedTXs} =
		filter_out_of_order_txs(WalletList, InTXs, OutTXs),
	case PassedTXs of
		[] ->
			lists:reverse(OutTXs);
		OutTXs ->
			lists:reverse(OutTXs);
		_ ->
			RemainingInTXs = InTXs -- PassedTXs,
			filter_all_out_of_order_txs(
				FloatingWalletList,
				RemainingInTXs,
				PassedTXs
			)
	end.

%% @doc Takes a wallet list and a set of txs and checks to ensure that the
%% txs can be iteratively applied. When a tx is encountered that cannot be
%% applied it is disregarded. The return is a tuple containing the output
%% wallet list and the set of applied transactions.
%% Helper function for 'filter_all_out_of_order_txs'.
filter_out_of_order_txs(WalletList, InTXs) ->
	filter_out_of_order_txs(WalletList, InTXs, []).

filter_out_of_order_txs(WalletList, [], OutTXs) ->
	{WalletList, OutTXs};
filter_out_of_order_txs(WalletList, [T | RawTXs], OutTXs) ->
	UpdatedWalletList =
		case ar_tx:check_last_tx(WalletList, T) of
			true  -> apply_tx(WalletList, T);
			false -> WalletList
		end,
	filter_out_of_order_txs(
		UpdatedWalletList,
		RawTXs,
		[T | OutTXs]
	).

%% @doc Generate a re-producible hash from a wallet list.
hash(WalletList) ->
	Bin =
		<<
			<< Addr/binary, (binary:encode_unsigned(Balance))/binary, LastTX/binary >>
		||
			{Addr, Balance, LastTX} <- WalletList
		>>,
	crypto:hash(?HASH_ALG, Bin).

%% @doc Ensure that all wallets in the wallet list are well-formed:
%% - if empty, have a last_tx;
%% - have a positive balance;
%% - have three fields.
validate([]) ->
	true;
validate([{_, 0, Last} | _]) when byte_size(Last) == 0 ->
	false;
validate([{_, Qty, _} | _]) when Qty < 0 ->
	false;
validate([{_,_,_} | Rest]) ->
	validate(Rest);
validate(_) ->
	false.

%%%% Private

%% @doc Alter a wallet in a wallet list.
alter_wallet(WalletList, Target, Adjustment) ->
	case lists:keyfind(Target, 1, WalletList) of
		false ->
			maybe_append_wallet(WalletList, {Target, Adjustment, <<>>});
		{Target, Balance, LastTX} ->
			maybe_replace_wallet(WalletList, {Target, Balance + Adjustment, LastTX})
	end.

%% @doc Perform the concrete application of a transaction to
%% a prefiltered wallet list.
do_apply_tx(
		WalletList,
		#tx {
			id = ID,
			owner = From,
			last_tx = Last,
			target = To,
			quantity = Qty,
			reward = Reward
		}) ->
	Addr = ar_wallet:to_address(From),
	case lists:keyfind(Addr, 1, WalletList) of
		{Addr, Balance, Last} ->
			NewWalletList = maybe_replace_wallet(
				WalletList,
				{Addr, Balance - (Qty + Reward), ID}
			),
			case lists:keyfind(To, 1, NewWalletList) of
				false ->
					maybe_append_wallet(NewWalletList, {To, Qty, <<>>});
				{To, OldBalance, LastTX} ->
					maybe_replace_wallet(NewWalletList, {To, OldBalance + Qty, LastTX})
			end;
		_ ->
			WalletList
	end.

maybe_append_wallet(WalletList, {_,0,_}) -> WalletList;
maybe_append_wallet(WalletList, Wallet)  -> [Wallet | WalletList].

maybe_replace_wallet(WalletList, {_,0,_}) -> WalletList;
maybe_replace_wallet(WalletList, Wallet={Addr,_,_}) ->
	lists:keyreplace(Addr, 1, WalletList, Wallet).