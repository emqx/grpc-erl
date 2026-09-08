%%--------------------------------------------------------------------
%% Copyright (c) 2020 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------

-module(grpc_client).

-behaviour(gen_server).

-include("grpc.hrl").

%% APIs
-export([ unary/4
        , health_check/2]).

-export([ open/3
        , close/2
        , close_async/1
        , send/2
        , send/3
        , send/4
        , recv/1
        , recv/2
        , async_install_receiver/2
        , map_recv_async_reply/2
        ]).

-export([trailers_to_error/1]).

-export([start_link/4]).

%% gen_server callbacks
-export([ init/1
        , handle_call/3
        , handle_cast/2
        , handle_info/2
        , handle_continue/2
        , terminate/2
        , code_change/3
        ]).

-export_type([ client_options/0
             , options/0
             , grpcstream/0]).

-define(active_owner, active_owner).
-define(undefined, undefined).

-record(state, {
          %% Pool name
          pool,
          %% The worker id in the pool
          id,
          %% Server address
          server :: server(),
          %% Gun connection pid
          gun_pid :: undefined | pid(),
          %% The Monitor referebce for gun connection pid
          mref :: undefined | reference(),
          %% Clean timer reference
          tref :: undefined | reference(),
          %% Encoding for gRPC packets
          %% XXX: Bad impl.
          encoding :: grpc_frame:encoding(),
          %% Streams
          streams :: #{stream_ref() => stream()},
          %% Client options
          client_opts :: client_options(),
          %% Flush timer reference
          flush_timer_ref :: undefined | reference(),
          %% Gun connection state
          gun_state :: up | down
         }).

-record(recv_async_caller, {dest :: active_owner()}).
-type recv_async_caller() :: #recv_async_caller{}.

-record(recv_async_reply_fn, {fn, args, alias}).
-type recv_async_reply_fn() :: #recv_async_reply_fn{}.

%% calls/casts/infos/continues
-record(close, {stream_ref :: stream_ref()}).
-record(install_receiver, {
    stream_ref :: stream_ref(),
    mode :: recv_async_mode(),
    dest :: recv_async_caller() | recv_async_reply_fn()
}).

-type stream_ref() :: gun:stream_ref().
-type request() :: map().

-type response() :: map().

-type eos_msg() :: {eos, list()}.

-type options() ::
        #{ channel => term()
         %% The grpc-encoding method
         %% Default is identity
         , encoding => grpc_frame:encoding()
         %% Content type to use in grpc header.
         %% Default is `application/grpc+json`
         , content_type => binary()
         %% The timeout to receive the response of request. The clock starts
         %% ticking when the request is sent
         %%
         %% Time is in milliseconds
         %%
         %% Default is infinity
         , timeout => non_neg_integer()
         %% Connection time-out time, used during the initial request,
         %% when the client is connecting to the server
         %%
         %% Time is in milliseconds
         %%
         %% Default equal to timeout option
         , connect_timeout => non_neg_integer()
         %% Whether to exit the client process
         %% when the connection process exits
         %% Default is true, as in gen.erl and gen_server.erl
         , exit_on_connection_crash => boolean()
         }.

-type def() ::
        #{ path := binary()
         , service := atom()
         , message_type := binary()
         , marshal := function()
         , unmarshal := function()
         }.

-type server() :: {http | https, string(), inet:port_number()}.

-type client_options() ::
        #{ encoding => grpc_frame:encoding()
         , gun_opts => gun:opts()
         , stream_batch_size => non_neg_integer()
         , stream_batch_delay_ms => non_neg_integer()
         }.

-define(DEFAULT_GUN_OPTS,
        #{protocols => [http2],
          connect_timeout => 5000,
          http2_opts => #{keepalive => 60000},
          tcp_opts => [{nodelay, true}]
         }).

-define(STREAM_RESERVED_TIMEOUT, 15000).

-define(DEFAULT_STREAMING_DELAY, 20).
-define(DEFAULT_STREAMING_BATCH_SIZE, 16384).

-define(IS_SILENCED_STREAM_ERROR(ERR),
    ((ERR) =:= normal orelse
     (ERR) =:= {stream_error,no_error,'Stream reset by server.'} orelse
     (ERR) =:= {stream_error,refused_stream,'Stream reset by server.'} orelse
     (ERR) =:= {closed,{error,closed}} orelse
     (ERR) =:= closed orelse
     (ERR) =:= {goaway,protocol_error,'The connection is going away.'})
).

-type stream_state() :: idle | open | closed.

-type stream() :: #{ st       := {LocalState :: stream_state(),
                                  RemoteState :: stream_state()}
                   , mqueue   := [binary() | {eos, trailers()}]
                   , hangs    := [{caller(), ts()}]
                   , ?active_owner := ?undefined | recv_async_caller() | recv_async_reply_fn()
                   , recvbuff := binary()
                   , sendbuff := iolist()
                   , sendbuff_size := non_neg_integer()
                   , sendbuff_last_flush_ts := non_neg_integer()
                   , encoding := grpc_frame:encoding()
                   }.
-type ts() :: integer().
%% gun:resp_headers() (not exported)
-type trailers() :: [{binary(), binary()}].
-type caller() :: gen_server:from().
-type active_owner() :: erlang:send_destination().

-type client_pid() :: pid().

-type grpcstream() :: #{ client_pid := client_pid()
                       , stream_ref := reference()
                       , def := def()
                       }.

-type recv_async_opts() :: #{
    mode := recv_async_mode(),
    reply_fn => {function(), [term()]}
}.
-type recv_async_mode() :: once | active.

-dialyzer({nowarn_function, [have_buffered_bytes/1]}).

%%--------------------------------------------------------------------
%% APIs
%%--------------------------------------------------------------------

-spec start_link(term(), pos_integer(), server(), client_options())
    -> {ok, pid()} | ignore | {error, term()}.
start_link(Pool, Id, Server, Opts) when is_map(Opts)  ->
    gen_server:start_link(?MODULE, [Pool, Id, Server, Opts], []).

%%--------------------------------------------------------------------
%% gRPC APIs

-spec unary(def(), request(), grpc:metadata(), options())
    -> {ok, response(), grpc:metadata()}
     | {error, {grpc_status_name(), grpc_message()}}
     | {error, term()}.
%% @doc Unary function call
unary(Def, Req, Metadata, Options) ->
    case open(Def, Metadata, Options) of
        {ok, GStream} ->
            _ = send(GStream, Req, fin, Options),
            case recv(GStream, Options) of
                {ok, [Resp]} when is_map(Resp) ->
                    {ok, [{eos, Trailers}]} = recv(GStream, Options),
                    {ok, Resp, Trailers};
                {ok, [{eos, Trailers}]} ->
                    %% Not data responed, only error trailers
                    {error, trailers_to_error(Trailers)};
                {ok, [Resp, Trailers]} ->
                    {ok, Resp, Trailers};
                {error, _} = E -> E
            end;
        E -> E
    end.

-spec open(def(), grpc:metadata(), options())
    -> {ok, grpcstream()}
     | {error, term()}.
open(Def, Metadata, Options0) ->
    ClientPid = pick(
                  maps:get(channel, Options0, undefined),
                  maps:get(key_dispatch, Options0, self())
                 ),
    case ClientPid of
        _ when is_pid(ClientPid) ->
            ConnectTimeout = connect_timeout(Options0),
            Options = Options0#{timeout => ConnectTimeout},
            case call(ClientPid, {open, Def, Metadata, Options0}, Options) of
                {ok, StreamRef} ->
                    {ok, #{stream_ref => StreamRef, client_pid => ClientPid, def => Def}};
                {error, _} = Error ->
                    Error
            end;
        false ->
            {error, no_workers}
    end.

close(GStream, Options) ->
    #{ client_pid := ClientPid
     , stream_ref := StreamRef
     } = GStream,
    call(ClientPid, #close{stream_ref = StreamRef}, Options).

close_async(GStream) ->
    #{ client_pid := ClientPid
     , stream_ref := StreamRef
     } = GStream,
    gen_server:cast(ClientPid, #close{stream_ref = StreamRef}).

connect_timeout(Options) ->
    maps:get(
      connect_timeout,
      Options,
      timeout(Options)
     ).

timeout(Options) ->
    maps:get(timeout, Options, infinity).

exit_on_connection_crash(Options) ->
    maps:get(exit_on_connection_crash, Options, true).

-spec send(grpcstream(), request()) -> ok.
send(GStream, Req) ->
    send(GStream, Req, nofin).

-spec send(grpcstream(), request(), fin | nofin) -> ok | no_return().
send(GStream, Req, IsFin) ->
    send(GStream, Req, IsFin, #{}).

-spec send(grpcstream(), request(), fin | nofin, options()) -> ok.
send(_GStream = #{
             def        := Def,
             client_pid := ClientPid,
             stream_ref := StreamRef
          }, Req, IsFin, Options) ->
    #{marshal := Marshal} = Def,
    Bytes = Marshal(Req),
    case call(ClientPid, {send, StreamRef, Bytes, IsFin}, Options) of
        ok -> ok;
        {error, R} -> error(R)
    end.

-spec recv(grpcstream())
    -> {ok, [response() | eos_msg()]}
     | {error, term()}.
recv(GStream) ->
    recv(GStream, #{}).

-spec recv(grpcstream(), timeout() | options())
    -> {ok, [response() | eos_msg()]}
     | {error, term()} | no_return().
recv(GStream, Timeout) when is_integer(Timeout) ->
    recv(GStream, #{timeout => Timeout});
recv(#{def        := Def,
       client_pid := ClientPid,
       stream_ref := StreamRef}, Options) ->
    Timeout = timeout(Options),
    Unmarshal = maps:get(unmarshal, Def),
    EndTS = case Timeout of
                infinity -> infinity;
                _ -> erlang:system_time(millisecond) + Timeout
            end,
    case call(ClientPid, {read, StreamRef, EndTS}, Options) of
        {error, _} = E -> E;
        {ok, Frames} ->
            Msgs = lists:map(fun({eos, Trailers}) -> {eos, Trailers};
                         (Bin) -> Unmarshal(Bin)
                   end, Frames),
            {ok, Msgs}
    end.

-doc """
Sets the client owning the stream to send replies back to the caller via async messages.

With `once` mode, only one such message is sent and then the stream "forgets" about the
caller.  Same as calling `recv` with `infinity` timeout, and without blocking.  Errors are
also forwarded.  If the associated `grpc_client` process dies, a `DOWN` message is
received.

With `active` mode, any queued messages and all future messages are forwarded to the
caller, which must decode `{ok, _}` with `map_recv_async_reply/2`.  Errors are also
forwarded.  If the associated `grpc_client` process dies, a `DOWN` message is received.
If the caller wishes to stop receiving messages and monitoring the `grpc_client` process,
it must explicitly demonitor the returned handle with `erlang:demonitor`.

Sent messages are of the form
`{grpc_reply, Handle, {ok, [binary() | eos_msg()]} | {error, any()}}`
""".
-spec async_install_receiver(grpcstream(), recv_async_opts()) -> reference().
async_install_receiver(GStream, Opts) when
    map_get(mode, Opts) == once;
    map_get(mode, Opts) == active
->
    #{mode := Mode} = Opts,
    #{ client_pid := ClientPid
     , stream_ref := StreamRef
     } = GStream,
    UnaliasOpt =
        case Mode of
            once -> reply_demonitor;
            active -> demonitor
        end,
    ReplyAlias = monitor(process, ClientPid, [{alias, UnaliasOpt}]),
    Dest =
        case Opts of
            #{reply_fn := {Fn, Args}} when is_function(Fn), is_list(Args) ->
                #recv_async_reply_fn{fn = Fn, args = Args, alias = ReplyAlias};
            #{} ->
                #recv_async_caller{dest = ReplyAlias}
        end,
    RecvAsync = #install_receiver{dest = Dest, mode = Mode, stream_ref = StreamRef},
    ok = gen_server:cast(ClientPid, RecvAsync),
    ReplyAlias.

-spec map_recv_async_reply(grpcstream(), [binary() | eos_msg()]) -> [map() | eos_msg()].
map_recv_async_reply(GStream, Frames) when is_list(Frames) ->
    #{def := Def} = GStream,
    Unmarshal = maps:get(unmarshal, Def),
    lists:map(
      fun({eos, Trailers}) ->
              {eos, Trailers};
         (Bin) ->
              Unmarshal(Bin)
      end,
      Frames).

-spec health_check(pid(), options()) -> ok | {error, term()}.
health_check(Worker, Options) ->
    ConnectTimeout = connect_timeout(Options),
    try
        call(Worker, health_check, Options#{timeout => ConnectTimeout})
    catch
        exit:{timeout, _Details} ->
            {error, timeout};
        exit:Reason when
            Reason =:= normal;
            Reason =:= {shutdown, normal}
        ->
            %% Race condition: gun went down while checking health?
            %% Try again.
            health_check(Worker, Options);
        exit:Reason ->
            {error, {grpc_client_down, Reason}}
    end.

%%--------------------------------------------------------------------
%% gen_server callbacks
%%--------------------------------------------------------------------

init([Pool, Id, Server = {_, _, _}, ClientOpts0]) ->
    set_label({grpc_client, Pool, Id}),
    Encoding = maps:get(encoding, ClientOpts0, identity),
    GunOpts = maps:get(gun_opts, ClientOpts0, #{}),
    Opts = ClientOpts0#{gun_opts => maps:merge(?DEFAULT_GUN_OPTS, GunOpts)},
    true = gproc_pool:connect_worker(Pool, {Pool, Id}),
    {ok, ensure_clean_timer(
           #state{
              pool = Pool,
              id = Id,
              gun_pid = undefined,
              server = Server,
              encoding = Encoding,
              streams = #{},
              client_opts = Opts,
              gun_state = down}), {continue, connect}}.

handle_continue(connect, State) ->
    case do_connect(State) of
        {error, Reason} ->
            logger:error("[grpc_client] connect to ~p failed: ~p", [State#state.server, Reason]),
            {noreply, State};
        NState ->
            {noreply, NState}
    end.

handle_call(Req, From, State = #state{gun_pid = undefined}) ->
    case do_connect(State) of
        {error, Reason} ->
            {reply, {error, Reason}, State#state{gun_state = down}};
        NState ->
            handle_call(Req, From, NState)
    end;
handle_call(health_check, _From, State = #state{gun_state = up}) ->
    {reply, ok, State};
handle_call(health_check, _From, State = #state{gun_state = down}) ->
    case do_connect(State) of
        {error, Reason} ->
            {reply, {error, Reason}, State#state{gun_state = down}};
        NState ->
            {reply, ok, NState}
    end;
handle_call({open, #{path := Path,
                     message_type := MessageType
                    }, Metadata, Options},
            _From,
            State = #state{gun_pid = GunPid, streams = Streams, encoding = Encoding}) ->
    Timeout = maps:get(timeout, Options, infinity),
    ContentType = maps:get(content_type, Options, <<"application/grpc+proto">>),
    Headers = assemble_grpc_headers(atom_to_binary(Encoding, utf8),
                                    ContentType,
                                    MessageType,
                                    Timeout,
                                    Metadata
                                   ),
    StreamRef = gun:post(GunPid, Path, Headers),
    Stream = #{st       => {open, idle},
               mqueue   => [],
               hangs    => [],
               ?active_owner => ?undefined,
               recvbuff => <<>>,
               sendbuff => [],
               sendbuff_size => 0,
               sendbuff_last_flush_ts => 0,
               encoding => Encoding
              },
    NState = State#state{streams = Streams#{StreamRef => Stream}},
    {reply, {ok, StreamRef}, NState};
handle_call(_Req = {send, StreamRef, Bytes, IsFin},
            _From,
            State = #state{gun_pid = GunPid, streams = Streams, encoding = Encoding,
                           client_opts = ClientOpts}) ->
    case maps:get(StreamRef, Streams, undefined) of
        Stream = #{st := {open, _RS}} ->
            NBytes = grpc_frame:encode(Encoding, Bytes),
            BatchSize = maps:get(
                          stream_batch_size,
                          ClientOpts,
                          ?DEFAULT_STREAMING_BATCH_SIZE
                         ),
            NStream = maybe_send_data(NBytes, IsFin, StreamRef, Stream, GunPid, BatchSize),
            NStreams = Streams#{StreamRef => NStream},
            {reply, ok, ensure_flush_timer(State#state{streams = NStreams})};
        #{st := {closed, _RS}} ->
            {reply, {error, closed}, State#state{gun_state = down}};
        undefined ->
            {reply, {error, not_found}, State};
        _S ->
            {reply, {error, bad_stream}, State}
    end;
handle_call(_Req = {read, StreamRef, EndTS},
            From,
            State0 = #state{streams = Streams}) ->
    case maps:get(StreamRef, Streams, undefined) of
        undefined ->
            {reply, {error, not_found}, State0};
        Stream ->
            State =
                handle_stream_handle_result(
                  stream_handle({read, From, StreamRef, EndTS}, Stream),
                  StreamRef,
                  Streams,
                  State0),
            {noreply, State}
    end;
handle_call(#close{stream_ref = StreamRef}, _From, State0) ->
    State = handle_close_stream(StreamRef, State0),
    {reply, ok, State};
handle_call(_Request, _From, State) ->
    {reply, {error, unkown_request}, State}.

handle_cast(#close{stream_ref = StreamRef}, State0) ->
    State = handle_close_stream(StreamRef, State0),
    {noreply, State};
handle_cast(#install_receiver{} = RecvAsync, State0) ->
    State = handle_recv_async(RecvAsync, State0),
    {noreply, State};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({timeout, TRef, clean_stopped_stream},
            State = #state{tref = TRef, streams = Streams}) ->
    NowTS = erlang:system_time(millisecond),
    NStreams = maps:filter(
                 fun(_, #{stopped := Stoppedts}) ->
                       NowTS < Stoppedts + ?STREAM_RESERVED_TIMEOUT;
                    (_, _) -> true
                 end, Streams),
    {noreply, ensure_clean_timer(State#state{streams = NStreams, tref = undefined})};
handle_info({timeout, TRef, flush_streams_sendbuff},
            State0 = #state{flush_timer_ref = TRef}) ->
    State = State0#state{flush_timer_ref = undefined},
    NowTS = erlang:system_time(millisecond),
    {noreply, ensure_flush_timer(flush_streams(NowTS, State))};
handle_info({gun_up, GunPid, http2}, State = #state{gun_pid = GunPid}) ->
    {noreply, State#state{gun_state = up}};
handle_info({gun_down, GunPid, http2, Reason, KilledStreamRefs},
            State0 = #state{gun_pid = GunPid}) ->
    State = reply_gun_down_drop_streams(Reason, KilledStreamRefs, State0),
    {noreply, State#state{gun_state = down}};
handle_info({'DOWN', MRef, process, GunPid, Reason},
            State0 = #state{mref = MRef, gun_pid = GunPid}) ->
    State = reply_gun_down_drop_streams(Reason, all, State0),
    {noreply, State#state{gun_pid = undefined, gun_state = down}};
handle_info(Info, #state{streams = Streams} = State0) when is_tuple(Info) ->
    Ls = [gun_response, gun_trailers, gun_data, gun_error],
    case lists:member(element(1, Info), Ls) of
        true ->
            StreamRef = element(3, Info),
            case StreamRef of
                {stop, {goaway, StreamID, ErrCode, _AddData}, Reason} ->
                    %% Ignore the goaway message; the state of the stream
                    %% will be cleared in the gun_down event
                    ?LOG(debug, "[gRPC Client] Stream ~w goaway, "
                                "error_code: ~0p, details: ~0p",
                                [StreamID, ErrCode, Reason]),
                    {noreply, State0};
                _ ->
                    case maps:get(StreamRef, Streams, undefined) of
                        undefined ->
                            LogLevel = unknown_stream_ref_log_level(Info),
                            ?LOG(LogLevel, "[gRPC Client] Unknown stream ref: ~0p, "
                                          "event: ~0p", [StreamRef, Info]),
                            {noreply, State0};
                        Stream ->
                            State =
                                handle_stream_handle_result(
                                  stream_handle(Info, Stream),
                                  StreamRef,
                                  Streams,
                                  State0),
                            {noreply, State}
                    end
            end;
        _ ->
            ?LOG(warning, "[gRPC Client] Unexpected info: ~p~n", [Info]),
            {noreply, State0}
    end.

unknown_stream_ref_log_level({gun_error, _, _, {stream_error,no_error,'Stream reset by server.'}}) ->
    debug;
unknown_stream_ref_log_level({gun_error, _, _, {closed,{error,closed}}}) ->
    debug;
unknown_stream_ref_log_level(_) ->
    warning.

terminate(_Reason, #state{pool = Pool, id = Id}) ->
    %% "hangs" and active owner will be notified by `exit:{noproc, _}` and `{'DOWN', _, _,
    %% _, _}`, respectively.
    gproc_pool:disconnect_worker(Pool, {Pool, Id}).

%% downgrade to Vsn
code_change({down, _Vsn},
            State = #state{
                       client_opts = ClientOpts,
                       flush_timer_ref = TRef
                      }, [Vsn]) ->
    NState =
        case re:run(Vsn, "0\\.6\\.[0-6]$", [{capture, none}]) of
            match ->
                GunOpts = maps:get(gun_opts, ClientOpts, ?DEFAULT_GUN_OPTS),
                _ = is_reference(TRef) andalso erlang:cancel_timer(TRef),
                %% flush all streams to avoid buffered data lost
                State1 = flush_streams(infinity, State),
                list_to_tuple(
                  lists:droplast(lists:droplast(tuple_to_list(State1)))
                  ++ [GunOpts]
                 );
            _ -> State
        end,
    {ok, NState};
%% upgrade from Vsn
code_change(_Vsn,
            {state,
             Pool, Id, Server, GunPid, MRef,
             TRef, Encoding, Streams, GunOpts}, [Vsn]) ->
    NState =
        case re:run(Vsn, "0\\.6\\.[0-6]$", [{capture, none}]) of
            match ->
                ClientOpts = #{encoding => Encoding,
                               gun_opts => GunOpts},
                NStreams = maps:map(
                             fun(_, Stream) ->
                                Stream#{
                                  sendbuff => [],
                                  sendbuff_size => 0,
                                  sendbuff_last_flush_ts => 0
                                 }
                             end, Streams),
                {state, Pool, Id, Server, GunPid, MRef,
                 TRef, Encoding, NStreams, ClientOpts, undefined};
            _ -> error({bad_vsn_in_code_change, Vsn})
        end,
    {ok, NState}.

%%--------------------------------------------------------------------
%% Handle stream handle

handle_stream_handle_result(ok, _StreamRef, Streams, State) ->
    State#state{streams = Streams};
handle_stream_handle_result({ok, Stream}, StreamRef, Streams, State) ->
    State#state{streams = Streams#{StreamRef => Stream}};
handle_stream_handle_result({ok, Events, Stream}, StreamRef, Streams, State) ->
    _ = run_events(Events),
    State#state{streams = Streams#{StreamRef => Stream}};
% shutdown on gun error
handle_stream_handle_result({shutdown, Reason, Stream}, StreamRef, Streams, State) ->
    LogLevel =
        case ?IS_SILENCED_STREAM_ERROR(Reason) of
            true -> debug;
            false -> warning
        end,
    ?LOG(LogLevel, "[gRPC Client] Stream shutdown reason: ~p, stream: ~s", [Reason, format_stream(Stream)]),
    reply_hangs(Stream, {error, Reason}),
    State#state{streams = maps:remove(StreamRef, Streams)};
% self-induced shutdown
handle_stream_handle_result({shutdown, Reason, Events, _Stream}, StreamRef, Streams, State) ->
    ?IS_SILENCED_STREAM_ERROR(Reason) orelse
        ?LOG(error, "[gRPC Client] Stream shutdown reason: ~p, stream: ~s",
             [Reason, format_stream(_Stream)]),
    _ = run_events(Events),
    State#state{streams = maps:remove(StreamRef, Streams)}.

run_events([]) ->
    ok;
run_events([{reply, From, Msg}|Es]) ->
    reply_caller(From, Msg),
    run_events(Es).

reply_caller(#recv_async_caller{dest = Dest}, Msg) ->
    _ = Dest ! {grpc_reply, Dest, Msg},
    ok;
reply_caller(#recv_async_reply_fn{fn = Fn, args = Args, alias = ReplyAlias}, Msg) ->
    try
        _ = apply(Fn, [Msg, ReplyAlias | Args]),
        ok
    catch
        Kind:Reason:Stacktrace ->
            ?LOG(error, "[gRPC Client] reply fn crashed: ~p", [{Kind, Reason, Stacktrace}]),
            ok
    end;
reply_caller({_, _} = From, Msg) ->
    %% gen_server:from()
    _ = gen_server:reply(From, Msg),
    ok.

%%--------------------------------------------------------------------
%% Streams handle
%%--------------------------------------------------------------------

%% api calls
stream_handle({read, From, _StreamRef, EndTS},
             Stream = #{mqueue := [], hangs := Hangs}) ->
    {ok, Stream#{hangs => [{From, EndTS}|Hangs]}};
stream_handle({read, From, _StreamRef, _EndTS},
              Stream = #{st := {_LS, open}, mqueue := MQueue}) when MQueue /= [] ->
    {ok, [{reply, From, {ok, MQueue}}], Stream#{mqueue => []}};
stream_handle({read, From, _StreamRef, _EndTS},
    Stream = #{st := {_LS, closed}, mqueue := MQueue}) when MQueue /= [] ->
    {shutdown, normal, [{reply, From, {ok, MQueue}}], Stream#{mqueue => []}};
stream_handle({read, From, _StreamRef, _EndTS},
              Stream = #{st := {closed, closed}, mqueue := MQueue}) ->
    {shutdown, normal, [{reply, From, {ok, MQueue}}], Stream#{mqueue => []}};
%% gun msgs
stream_handle({gun_response, _GunPid, _StreamRef, IsFin, _Status, Headers},
              Stream = #{st := {_LS, idle}}) ->
    case IsFin of
        nofin ->
            {ok, Stream#{st => {_LS, open}}};
        fin ->
            handle_remote_closed(Headers, Stream)
    end;
stream_handle({gun_trailers, _GunPid, _StreamRef, Trailers},
              Stream = #{st := {_LS, open}}) ->
    handle_remote_closed(Trailers, Stream);
stream_handle({gun_data, _GunPid, _StreamRef, nofin, Data},
              Stream = #{st := {_LS, open},
                         recvbuff := Acc,
                         encoding := Encoding}) ->
    NData = <<Acc/binary, Data/binary>>,
    case grpc_frame:split(NData, Encoding) of
        {Rest, []} ->
            {ok, Stream#{recvbuff := Rest}};
        {Rest, Frames} ->
            case clean_hangs(Stream#{recvbuff := Rest}) of
                #{hangs := [], ?active_owner := ?undefined, mqueue := MQueue} = NStream ->
                    {ok, NStream#{mqueue := MQueue ++ Frames}};
                #{?active_owner := Caller, mqueue := MQueue} = NStream when
                      Caller /= ?undefined
                ->
                    {ok, [{reply, Caller, {ok, MQueue ++ Frames}}], NStream#{mqueue := []}};
                #{hangs := [{_From, _}|_NHangs] = Hangs, mqueue := MQueue} = NStream ->
                    Replies = lists:map(fun({From, _}) -> {reply, From, {ok, MQueue ++ Frames}} end, Hangs),
                    {ok, Replies, NStream#{hangs := [], mqueue := []}}
            end
    end;
stream_handle({gun_data, _GunPid, _StreamRef, fin, Data},
               Stream = #{st := {_LS, open},
                         recvbuff := Acc,
                         encoding := Encoding}) ->
    NData = <<Acc/binary, Data/binary>>,
    case grpc_frame:split(NData, Encoding) of
        {<<>>, []} ->
            handle_remote_closed([], Stream);
        {<<>>, Frames} ->
            MQueue = maps:get(mqueue, Stream),
            handle_remote_closed([], Stream#{recvbuff := <<>>, mqueue := MQueue ++ Frames})
    end;
stream_handle({gun_error, _GunPid, _StreamRef, {stream_error, no_error, 'Stream reset by server.'}},
              Stream = #{st := {_LS, closed}, mqueue := MQueue}) when MQueue =/= [] ->
    {ok, Stream};
stream_handle({gun_error, _GunPid, _StreamRef, Reason}, Stream) ->
    {shutdown, Reason, Stream};
stream_handle(Info, Stream) ->
    ?LOG(error, "Unexecpted stream event: ~p, stream ~0p", [Info, Stream]).

handle_remote_closed(Trailers, Stream = #{st := {closed, _}}) ->
    case clean_hangs(Stream#{st => {closed, closed}}) of
        #{?active_owner := Caller, mqueue := MQueue} = NStream when
              Caller /= ?undefined
        ->
            #{hangs := Hangs} = NStream,
            Event1 = {reply, Caller, {ok, MQueue ++ [{eos, Trailers}]}},
            Events2 = lists:map(fun({F, _}) -> {reply, F, {error, closed}} end, Hangs),
            {shutdown, normal, [Event1 | Events2], NStream#{hangs => [], mqueue => []}};
        #{hangs := [{From, _}|NHangs], mqueue := MQueue} = NStream ->
            Events1 = [{reply, From, {ok, MQueue ++ [{eos, Trailers}]}}],
            Events2 = lists:map(fun({F, _}) -> {reply, F, {error, closed}} end, NHangs),
            {shutdown, normal, Events1 ++ Events2, NStream#{hangs => [], mqueue => []}};
        #{hangs := [], mqueue := MQueue} = NStream ->
            {ok, NStream#{mqueue => MQueue ++ [{eos, Trailers}],
                          stopped => erlang:system_time(millisecond)}}
    end;
handle_remote_closed(Trailers, Stream = #{st := {Ls, _}}) ->
    case clean_hangs(Stream#{st => {Ls, closed}}) of
        #{?active_owner := Caller, mqueue := MQueue} = NStream when
              Caller /= ?undefined
        ->
            #{hangs := Hangs} = NStream,
            Event1 = {reply, Caller, {ok, MQueue ++ [{eos, Trailers}]}},
            Events2 = lists:map(fun({F, _}) -> {reply, F, {error, closed}} end, Hangs),
            {shutdown, normal, [Event1 | Events2], NStream#{hangs => [], mqueue => []}};
        #{hangs := [{From, _}|NHangs], mqueue := MQueue} = NStream ->
            Events1 = [{reply, From, {ok, MQueue ++ [{eos, Trailers}]}}],
            Events2 = lists:map(fun({F, _}) -> {reply, F, {error, closed}} end, NHangs),
            {ok, Events1 ++ Events2, NStream#{hangs => [], mqueue => []}};
        #{hangs := [], mqueue := MQueue} = NStream ->
            {ok, NStream#{mqueue => MQueue ++ [{eos, Trailers}]}}
    end.

clean_hangs(Stream = #{hangs := []}) ->
    Stream;
clean_hangs(Stream = #{hangs := Hangs}) ->
    NowTS = erlang:system_time(millisecond),
    Hangs1 = lists:filter(fun({_, T}) -> T >= NowTS end, Hangs),
    Stream#{hangs => Hangs1}.

%% if there are any calls waiting on us, we must reply them.
reply_hangs(DroppedStream, Result) ->
    reply_active_owner(DroppedStream, Result),
    #{hangs := Hangs} = DroppedStream,
    lists:foreach(fun({From, _EndTS}) -> reply_caller(From, Result) end, Hangs).

reply_active_owner(DroppedStream, Result) ->
    case DroppedStream of
        #{?active_owner := Caller} when Caller /= ?undefined ->
            reply_caller(Caller, Result);
        #{} ->
            ok
    end.

reply_gun_down_drop_streams(Reason, WhichStreams, State0) ->
    NowTS = erlang:system_time(millisecond),
    #state{streams = Streams0} = State0,
    {KilledStreams, Streams} =
        case WhichStreams of
            all ->
                {Streams0, #{}};
            KilledStreamRefs ->
                {maps:with(KilledStreamRefs, Streams0),
                 maps:without(KilledStreamRefs, Streams0)}
        end,
    maps:foreach(
      fun(_, #{hangs := Hangs, ?active_owner := ActiveOwner}) ->
        case ActiveOwner of
            ?undefined ->
                ok;
            Caller ->
                reply_caller(Caller, {error, {connection_down, Reason}})
        end,
        lists:foreach(fun({From, EndTS}) ->
            EndTS > NowTS andalso
              reply_caller(From, {error, {connection_down, Reason}})
        end, Hangs)
      end,
      KilledStreams
     ),
    State0#state{streams = Streams}.

handle_close_stream(StreamRef, State0) ->
    #state{streams = Streams0} = State0,
    case maps:take(StreamRef, Streams0) of
        error ->
            State0;
        {Stream, Streams} ->
            State = State0#state{streams = Streams},
            case State#state.gun_pid of
                GunPid when is_pid(GunPid) ->
                    _ = gun:cancel(GunPid, StreamRef),
                    ok;
                _ ->
                    ok
            end,
            reply_hangs(Stream, {error, stream_closed}),
            State
    end.

handle_recv_async(#install_receiver{mode = once} = RecvAsync, State0) ->
    %% can emulate by using the existing read call with infinity timeout.
    #install_receiver{dest = Caller, stream_ref = StreamRef} = RecvAsync,
    #state{streams = Streams} = State0,
    case maps:find(StreamRef, Streams) of
        error ->
            reply_caller(Caller, {error, not_found}),
            State0;
        {ok, Stream0} ->
            EndTS = infinity,
            handle_stream_handle_result(
              stream_handle({read, Caller, StreamRef, EndTS}, Stream0),
              StreamRef,
              Streams,
              State0)
    end;
handle_recv_async(#install_receiver{mode = active} = RecvAsync, State0) ->
    %% With active recv mode, we want a single owner to receive all future messages from
    %% the stream until it dies.  If the owner of the stream dies, we currently don't
    %% quite care as likely a new owner will be spawned and will open a fresh stream
    %% anyway.  If there's a desire to avoid losing messages after an owner dies, then one
    %% may provide a reply fn that stores those elsewhere, e.g., in ETS.
    #install_receiver{dest = Caller, stream_ref = StreamRef} = RecvAsync,
    #state{streams = Streams} = State0,
    case maps:find(StreamRef, Streams) of
        error ->
            reply_caller(Caller, {error, not_found}),
            State0;
        {ok, Stream0} ->
            Stream = Stream0#{?active_owner := Caller},
            %% immediately flush anything buffered
            do_flush_recv_async(Stream, StreamRef, State0)
    end.

do_flush_recv_async(Stream, StreamRef, State0) ->
    #state{streams = Streams} = State0,
    #{?active_owner := Caller} = Stream,
    %% see `stream_handle/2`.
    Res =
        case Stream of
            #{st := {closed, closed}, mqueue := MQueue} ->
                {shutdown, normal, [{reply, Caller, {ok, MQueue}}], Stream#{mqueue => []}};
            #{st := {_LS, closed}, mqueue := MQueue} when MQueue /= [] ->
                {shutdown, normal, [{reply, Caller, {ok, MQueue}}], Stream#{mqueue => []}};
            #{st := {_LS, open}, mqueue := MQueue} when MQueue /= [] ->
                {ok, [{reply, Caller, {ok, MQueue}}], Stream#{mqueue => []}};
            #{} ->
                {ok, Stream}
        end,
    handle_stream_handle_result(Res, StreamRef, Streams, State0).

%%--------------------------------------------------------------------
%% Internal funcs
%%--------------------------------------------------------------------

do_connect(State0 = #state{server = {_, Host, Port}, client_opts = ClientOpts}) ->
    State = ensure_gun_stopped(State0),
    GunOpts = maps:get(gun_opts, ClientOpts, #{}),
    case gun:open(Host, Port, GunOpts) of
        {ok, Pid} ->
            %% NOTE
            %% By default, `gun` retries failed connection attempts 5 times, with
            %% 5 seconds delay in-between. Give it a bit more spare time, just in
            %% case.
            MRef = monitor(process, Pid),
            case gun:await_up(Pid, 60_000, MRef) of
                {ok, _Protocol} ->
                    State#state{mref = MRef, gun_pid = Pid, gun_state = up};
                {error, {down, Reason}} ->
                    demonitor(MRef, [flush]),
                    {error, Reason};
                {error, timeout} ->
                    _ = gun:close(Pid),
                    demonitor(MRef, [flush]),
                    {error, timeout}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

ensure_gun_stopped(#state{mref = OldMRef, gun_pid = Pid} = State0) when is_pid(Pid) ->
    MRef = monitor(process, Pid),
    _ = gun:close(Pid),
    receive
        {'DOWN', MRef, process, Pid, _} ->
            ok
    after
        1_000 ->
            exit(Pid, kill),
            receive {'DOWN', MRef, process, Pid, _} -> ok end,
            ok
    end,
    is_reference(OldMRef) andalso demonitor(OldMRef, [flush]),
    State0#state{mref = undefined, gun_pid = undefined};
ensure_gun_stopped(#state{} = State0) ->
    State0.

%%--------------------------------------------------------------------
%% Helpers

flush_streams(NowTS, State = #state{streams = Streams,
                                    gun_pid = GunPid,
                                    client_opts = ClientOpts}) ->
    Intv = maps:get(stream_batch_delay_ms, ClientOpts, ?DEFAULT_STREAMING_DELAY),
    NStreams =
        maps:map(
          fun(_, Stream = #{sendbuff_size := 0}) ->
                  Stream;
             (_, Stream = #{sendbuff_last_flush_ts := TS})
               when NowTS < (TS + Intv) ->
                  Stream;
             (StreamRef, Stream = #{sendbuff := IolistData,
                                    sendbuff_last_flush_ts := TS})
               when NowTS >= (TS + Intv) ->
                  ok = gun:data(GunPid, StreamRef, nofin, lists:reverse(IolistData)),
                  Stream#{sendbuff := [], sendbuff_size := 0, sendbuff_last_flush_ts := NowTS}
          end, Streams),
   State#state{streams = NStreams}.

maybe_send_data(Bytes, IsFin, StreamRef,
          Stream = #{st := {_, _RS},
                     sendbuff := IolistData0,
                     sendbuff_size := BufferSize0}, GunPid, BatchSize) ->
    IolistData = [Bytes | IolistData0],
    IolistSize = BufferSize0 + iolist_size(Bytes),
    case IsFin == fin orelse IolistSize >= BatchSize of
        true ->
            NData = lists:reverse(IolistData),
            ok = gun:data(GunPid, StreamRef, IsFin, NData),
            case IsFin of
                fin ->
                    Stream#{st := {closed, _RS},
                            sendbuff := [],
                            sendbuff_size := 0
                           };
                _ ->
                    Stream#{sendbuff := [],
                            sendbuff_size := 0
                           }
            end;
        false ->
            Stream#{sendbuff := IolistData, sendbuff_size := IolistSize}
    end.

trailers_to_error([]) ->
    stream_closed_without_any_response;
trailers_to_error(Trailers) ->
    {grpc_utils:codename(
       proplists:get_value(<<"grpc-status">>, Trailers, ?GRPC_STATUS_OK)
      ),
     proplists:get_value(<<"grpc-message">>, Trailers, <<>>)}.

ensure_clean_timer(State = #state{tref = undefined}) ->
    TRef = erlang:start_timer(?STREAM_RESERVED_TIMEOUT,
                              self(),
                              clean_stopped_stream),
    State#state{tref = TRef}.

ensure_flush_timer(State = #state{streams = Streams,
                                  flush_timer_ref = undefined,
                                  client_opts = ClientOpts
                                 }) ->
    case have_buffered_bytes(Streams) of
        true ->
            Intv = maps:get(stream_batch_delay_ms, ClientOpts, ?DEFAULT_STREAMING_DELAY),
            TRef = erlang:start_timer(Intv, self(), flush_streams_sendbuff),
            State#state{flush_timer_ref = TRef};
        _ ->
            State
    end;
ensure_flush_timer(State) ->
    State.

have_buffered_bytes(Streams) when is_map(Streams) ->
    have_buffered_bytes(maps:next(maps:iterator(Streams)));

have_buffered_bytes({_StreamRef, #{sendbuff_size := 0}, I}) ->
    have_buffered_bytes(maps:next(I));
have_buffered_bytes({_StreamRef, #{sendbuff_size := S}, _I}) when S > 0 ->
    true;
have_buffered_bytes({_StreamRef, #{sendbuff_size := S}, none}) ->
    S > 0;
have_buffered_bytes(none) ->
    false.

format_stream(#{st := St, recvbuff := Buff, mqueue := MQueue}) ->
    io_lib:format("#stream{st=~p, buff_size=~w, mqueue=~p}",
                  [St, byte_size(Buff), MQueue]).

%% copied from gen.erl and gen_server.erl
call(Process, Request, Options) ->
    Timeout = timeout(Options),
    ExitOnCrash = exit_on_connection_crash(Options),
    Mref = erlang:monitor(process, Process, [{alias, reply_demonitor}]),

    %% OTP-21:
    %% Auto-connect is asynchronous. But we still use 'noconnect' to make sure
    %% we send on the monitored connection, and not trigger a new auto-connect.
    %%
    erlang:send(Process, {'$gen_call', {Mref, Mref}, Request}, [noconnect]),

    receive
        {Mref, Reply} ->
            erlang:demonitor(Mref, [flush]),
            Reply;
        {'DOWN', Mref, _, _, Reason} ->
            call_result(ExitOnCrash, Reason)
    after Timeout ->
              erlang:demonitor(Mref, [flush]),
              receive
                {Mref, Reply} -> Reply
              after 0 ->
                {error, {grpc_utils:codename(?GRPC_STATUS_DEADLINE_EXCEEDED),
                        <<"Waiting for response timeout">>}}
              end
    end.

call_result(_ExitOnCrash = true, Reason) ->
    exit(Reason);
call_result(_ExitOnCrash = false, Reason) ->
    error({exit, Reason}).

pick(ChannName, Key) ->
    gproc_pool:pick_worker(ChannName, Key).

assemble_grpc_headers(Encoding, ContentType, MessageType, Timeout, MD) ->
    [{<<"content-type">>, ContentType},
     {<<"user-agent">>, <<"grpc-erlang/0.1.0">>},
     {<<"grpc-encoding">>, Encoding},
     {<<"grpc-message-type">>, MessageType},
     {<<"te">>, <<"trailers">>}]
    ++ assemble_grpc_timeout_header(Timeout)
    ++ assemble_grpc_metadata_header(MD).

assemble_grpc_timeout_header(infinity) ->
    [];
assemble_grpc_timeout_header(Timeout) ->
    [{<<"grpc-timeout">>, ms2timeout(Timeout)}].

assemble_grpc_metadata_header(MD) ->
    maps:to_list(MD).

ms2timeout(Ms) when Ms > 1000 ->
    [integer_to_list(Ms div 1000), $S];
ms2timeout(Ms) ->
    [integer_to_list(Ms), $m].

-if(OTP_RELEASE >= 27).
set_label(Label) -> proc_lib:set_label(Label).
-else.
set_label(_Label) -> ok.
-endif.
