-module(ar_tx_queue).
-behaviour(gen_server).

%% API
-export([start_link/0, stop/0]).
-export([set_max_emitters/1, set_max_header_size/1, set_max_data_size/1, set_pause/1]).
-export([add_tx/1, show_queue/0]).
-export([utility/1]).

%% gen_server callbacks
-export([
	init/1, handle_call/3, handle_cast/2,
	terminate/2, code_change/3, format_status/2
]).

-include("ar.hrl").

-record(state, {
	tx_queue,
	emitters_running,
	max_emitters,
	max_header_size,
	max_data_size,
	header_size,
	data_size,
	paused,
	emit_map
}).

-define(EMITTER_START_WAIT, 150).
-define(EMITTER_INTER_WAIT, 5).

%%%===================================================================
%%% Public interface.
%%%===================================================================

start_link() ->
	Resp =
		case gen_server:start_link({local, ?MODULE}, ?MODULE, [], []) of
			{ok, _Pid} ->
				ok;
			{error, {already_started, _Pid}} ->
				ok;
			Error ->
				ar:err({?MODULE, error_on_start_link, Error}),
				error
		end,
	case Resp of
		ok -> start_emitters();
		_  -> pass
	end.

start_emitters() ->
	gen_server:call(?MODULE, start_emitters).

stop() ->
	gen_server:stop(?MODULE).

set_pause(PauseOrNot) ->
	gen_server:call(?MODULE, {set_pause, PauseOrNot}).

set_max_header_size(Bytes) ->
	gen_server:call(?MODULE, {set_max_header_size, Bytes}).

set_max_data_size(Bytes) ->
	gen_server:call(?MODULE, {set_max_data_size, Bytes}).

set_max_emitters(N) ->
	gen_server:call(?MODULE, {set_max_emitters, N}).

add_tx(TX) ->
	gen_server:cast(?MODULE, {add_tx, TX}).

show_queue() ->
	gen_server:call(?MODULE, show_queue).

%%%===================================================================
%%% Generic server callbacks.
%%%===================================================================

init([]) ->
	MaxEmitters =
		case ar_meta_db:get(max_emitters) of
			not_found -> ?NUM_EMITTER_PROCESSES;
			X -> X
		end,
	{ok, #state{
		tx_queue = gb_sets:new(),
		emitters_running = 0,
		max_emitters = MaxEmitters,
		max_header_size = ?TX_QUEUE_HEADER_SIZE_LIMIT,
		max_data_size = ?TX_QUEUE_DATA_SIZE_LIMIT,
		header_size = 0,
		data_size = 0,
		paused = false,
		emit_map = #{}
	}}.

handle_call({set_pause, PauseOrNot}, _From, State) ->
	{reply, ok, State#state{ paused = PauseOrNot }};

handle_call({set_max_emitters, N}, _From, State) ->
	{reply, ok, State#state{ max_emitters = N }};

handle_call({set_max_header_size, Bytes}, _From, State) ->
	{reply, ok, State#state{ max_header_size = Bytes }};

handle_call({set_max_data_size, Bytes}, _From, State) ->
	{reply, ok, State#state{ max_data_size = Bytes }};

handle_call(show_queue, _From, State = #state{ tx_queue = Q }) ->
	Reply = show_queue(Q),
	{reply, Reply, State};

handle_call(start_emitters, _From, State) ->
	#state{ max_emitters = MaxEmitters, emitters_running = EmittersRunning } = State,
	lists:foreach(
		fun(N) ->
			Wait = N * ?EMITTER_START_WAIT,
			timer:apply_after(Wait, gen_server, cast, [?MODULE, emitter_go])
		end,
		lists:seq(1, max(MaxEmitters - EmittersRunning, 0))
	),
	{reply, ok, State#state{ emitters_running = MaxEmitters, paused = false }};

handle_call(_Request, _From, State) ->
	{noreply, State}.

handle_cast({add_tx, TX}, State) ->
	#state{
		tx_queue = Q,
		max_header_size = MaxHeaderSize,
		max_data_size = MaxDataSize,
		header_size = HeaderSize,
		data_size = DataSize
	} = State,
	{TXHeaderSize, TXDataSize} = tx_queue_size(TX),
	U = utility(TX),
	{NewQ, {NewHeaderSize, NewDataSize}, DroppedTXs} =
		maybe_drop(
			gb_sets:add_element({U, {TX, {TXHeaderSize, TXDataSize}}}, Q),
			{HeaderSize + TXHeaderSize, DataSize + TXDataSize},
			{MaxHeaderSize, MaxDataSize}
		),
	case DroppedTXs of
		[] ->
			noop;
		_ ->
			ar:info([
				{event, drop_txs_from_queue},
				{dropped_txs, lists:map(fun(T) -> ar_util:encode(T#tx.id) end, DroppedTXs)}
			]),
			ar_bridge:drop_waiting_txs(whereis(http_bridge_node), DroppedTXs)
	end,
	NewState = State#state{
		tx_queue = NewQ,
		header_size = NewHeaderSize,
		data_size = NewDataSize
	},
	{noreply, NewState};

handle_cast(emitter_go, State = #state{ paused = true }) ->
	timer:apply_after(?EMITTER_START_WAIT, gen_server, cast, [?MODULE, emitter_go]),
	{noreply, State};
handle_cast(emitter_go, State = #state{ emitters_running = EmittersRunning, max_emitters = MaxEmitters }) when EmittersRunning > MaxEmitters ->
	{noreply, State#state { emitters_running = EmittersRunning - 1}};
handle_cast(emitter_go, State) ->
	#state{
		tx_queue = Q,
		header_size = HeaderSize,
		data_size = DataSize,
		emit_map = EmitMap
	} = State,
	NewState =
		case gb_sets:is_empty(Q) of
			true ->
				timer:apply_after(?EMITTER_START_WAIT, gen_server, cast, [?MODULE, emitter_go]),
				State;
			false ->
				{{_, {TX, {TXHeaderSize, TXDataSize}}}, NewQ} = gb_sets:take_largest(Q),
				Bridge = whereis(http_bridge_node),
				Peers = lists:sublist(ar_bridge:get_remote_peers(Bridge), ar_meta_db:get(max_propagation_peers)),
				case Peers of
					[] ->
						gen_server:cast(?MODULE, {emitter_finished, TX}),
						State#state{
							tx_queue = NewQ,
							header_size = HeaderSize - TXHeaderSize,
							data_size = DataSize - TXDataSize
						};
					_ ->
						%% Send transactions to the "max_propagation_peers" best peers,
						%% tx_propagation_parallelization peers at a time. The resulting
						%% maximum for outbound connections is
						%% tx_propagation_parallelization * num_emitters.
						lists:foreach(
							fun(_) ->
								gen_server:cast(?MODULE, {emit_tx_to_peer, TX})
							end,
							lists:seq(1, ar_meta_db:get(tx_propagation_parallelization))
						),
						TXID = TX#tx.id,
						NewEmitMap = EmitMap#{ TXID => #{ peers => Peers, started_at => erlang:timestamp() } },
						State#state{
							tx_queue = NewQ,
							header_size = HeaderSize - TXHeaderSize,
							data_size = DataSize - TXDataSize,
							emit_map = NewEmitMap
						}
				end
		end,
	{noreply, NewState};

handle_cast({emit_tx_to_peer, TX}, State = #state{ emit_map = EmitMap }) ->
	#tx{ id = TXID } = TX,
	case EmitMap of
		#{ TXID := #{ peers := [] } } ->
			{noreply, State};
		#{ TXID := TXIDMap = #{ peers := [Peer | Peers] } } ->
			spawn(
				fun() ->
					Reply = ar_http_iface_client:send_new_tx(Peer, tx_to_propagated_tx(TX)),
					gen_server:cast(?MODULE, {emitted_tx_to_peer, {Reply, TX}})
				end
			),
			{noreply, State#state{ emit_map = EmitMap#{ TXID => TXIDMap#{ peers => Peers } } }};
		_ ->
			{noreply, State}
	end;

handle_cast({emitted_tx_to_peer, {Reply, TX}}, State = #state{ emit_map = EmitMap, tx_queue = Q }) ->
	TXID = TX#tx.id,
	case EmitMap of
		#{ TXID := #{ peers := [], started_at := StartedAt } } ->
			PropagationTimeUs = timer:now_diff(erlang:timestamp(), StartedAt),
			record_propagation_status(Reply),
			record_propagation_rate(tx_propagated_size(TX), PropagationTimeUs),
			record_queue_size(gb_sets:size(Q)),
			gen_server:cast(?MODULE, {emitter_finished, TX}),
			{noreply, State#state{ emit_map = maps:remove(TXID, EmitMap) }};
		_ ->
			gen_server:cast(?MODULE, {emit_tx_to_peer, TX}),
			{noreply, State}
	end;

handle_cast({emitter_finished, TX}, State) ->
	Bridge = whereis(http_bridge_node),
	timer:apply_after(
		ar_node_utils:calculate_delay(tx_propagated_size(TX)),
		ar_bridge,
		move_tx_to_mining_pool,
		[Bridge, TX]
	),
	timer:apply_after(?EMITTER_INTER_WAIT, gen_server, cast, [?MODULE, emitter_go]),
	{noreply, State};

handle_cast(_Request, State) ->
	{noreply, State}.

terminate(_Reason, _State) ->
	ok.

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

format_status(_Opt, Status) ->
	Status.

%%%===================================================================
%%% Private functions.
%%%===================================================================

maybe_drop(Q, Size, MaxSize) ->
	maybe_drop(Q, Size, MaxSize, []).

maybe_drop(Q, {HeaderSize, DataSize} = Size, {MaxHeaderSize, MaxDataSize} = MaxSize, DroppedTXs) ->
	case HeaderSize > MaxHeaderSize orelse DataSize > MaxDataSize of
		true ->
			{{_, {TX, {DroppedHeaderSize, DroppedDataSize}}}, NewQ} = gb_sets:take_smallest(Q),
			maybe_drop(
				NewQ,
				{HeaderSize - DroppedHeaderSize, DataSize - DroppedDataSize},
				MaxSize,
				[TX | DroppedTXs]
			);
		false ->
			{Q, Size, lists:filter(fun(TX) -> TX /= none end, DroppedTXs)}
	end.

show_queue(Q) ->
	gb_sets:fold(
		fun({_, {TX, _}}, Acc) ->
			[{ar_util:encode(TX#tx.id), TX#tx.reward, TX#tx.data_size} | Acc]
		end,
		[],
		Q
	).

utility(TX = #tx { data_size = DataSize }) ->
	utility(TX, ?TX_SIZE_BASE + DataSize).

utility(#tx { reward = Reward }, Size) ->
	erlang:trunc(Reward / Size).

tx_propagated_size(#tx{ format = 2 }) ->
	?TX_SIZE_BASE;
tx_propagated_size(#tx{ format = 1, data = Data }) ->
	?TX_SIZE_BASE + byte_size(Data).

tx_to_propagated_tx(#tx{ format = 1 } = TX) ->
	TX;
tx_to_propagated_tx(#tx{ format = 2 } = TX) ->
	TX#tx{ data = <<>> }.

tx_queue_size(#tx{ format = 1 } = TX) ->
	{tx_propagated_size(TX), 0};
tx_queue_size(#tx{ format = 2, data = Data }) ->
	{?TX_SIZE_BASE, byte_size(Data)}.

record_propagation_status(not_sent) ->
	ok;
record_propagation_status({ok, {{StatusBinary, _}, _, _, _, _}}) ->
	StatusClass = case catch binary_to_integer(StatusBinary) of
		200 ->
			"success";
		208 ->
			"already_processed";
		Status when is_integer(Status) ->
			prometheus_http:status_class(Status);
		_ ->
			"unknown"
	end,
	prometheus_counter:inc(propagated_transactions_total, [StatusClass]);
record_propagation_status({error, connection_closed}) ->
	prometheus_counter:inc(propagated_transactions_total, ["connection_closed"]);
record_propagation_status({error, connect_timeout}) ->
	prometheus_counter:inc(propagated_transactions_total, ["connect_timeout"]);
record_propagation_status({error, timeout}) ->
	prometheus_counter:inc(propagated_transactions_total, ["timeout"]);
record_propagation_status({error, econnrefused}) ->
	prometheus_counter:inc(propagated_transactions_total, ["econnrefused"]);
record_propagation_status(_Reply) ->
	prometheus_counter:inc(propagated_transactions_total, ["unknown"]).

record_propagation_rate(PropagatedSize, PropagationTimeUs) ->
	BitsPerSecond = PropagatedSize * 1000000 / PropagationTimeUs * 8,
	prometheus_histogram:observe(tx_propagation_bits_per_second, BitsPerSecond).

record_queue_size(QSize) ->
	prometheus_gauge:set(tx_queue_size, QSize).
