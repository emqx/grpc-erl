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

-module(grpc_test2_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").

-define(SERVER_NAME, server).
-define(SERVER_ADDR, "http://127.0.0.1:10000").
-define(CHANN_NAME, channel).

-define(LOG(Fmt, Args), io:format(standard_error, Fmt, Args)).

%%--------------------------------------------------------------------
%% Setups
%%--------------------------------------------------------------------

all() ->
    [t_deadline, t_health_check].

init_per_suite(Cfg) ->
    _ = application:ensure_all_started(grpc),
    Services = #{protos => [grpc_test_pb], services => #{'Test' => test_svr}},
    [{services, Services} | Cfg].

end_per_suite(_Cfg) ->
    _ = application:stop(grpc).

init_per_testcase(t_deadline, Cfg) ->
    {ok, _} = grpc:start_server(?SERVER_NAME, 10000, ?config(services, Cfg), []),
    {ok, _} = grpc_client_sup:create_channel_pool(?CHANN_NAME, ?SERVER_ADDR, #{}),
    Cfg;
init_per_testcase(t_health_check, Cfg) ->
    %% The case will handle the channel pool creation and server start by itself
    Cfg.

end_per_testcase(t_deadline, _Cfg) ->
    _ = grpc_client_sup:stop_channel_pool(?CHANN_NAME),
    _ = grpc:stop_server(?SERVER_NAME),
    ok;
end_per_testcase(t_health_check, _Cfg) ->
    ok.

%%--------------------------------------------------------------------
%% Tests
%%--------------------------------------------------------------------

t_deadline(_) ->
    ?assertMatch({error, {deadline_exceeded, _}},
                 test_client:test_deadline(#{ms => 3000},
                                           #{channel => ?CHANN_NAME,
                                             timeout => 2000}
                                          )),
    receive
        Msg ->
            ?assert({should_not_receive_a_garbage_msg, Msg})
    after 3000 ->
              ok
    end.

t_health_check(Cfg) ->
    Services = ?config(services, Cfg),
    {ok, _} = grpc:start_server(?SERVER_NAME, 10000, Services, []),
    {ok, _} = grpc_client_sup:create_channel_pool(?CHANN_NAME, ?SERVER_ADDR, #{}),

    WorkersHealthCheck =
        fun(Worker) ->
            case grpc_client:health_check(Worker, #{channel => ?CHANN_NAME}) of
                ok -> true;
                _ -> false
            end
        end,

    WorkersPid = [WorkerPid || {_, WorkerPid} <- grpc_client_sup:workers(?CHANN_NAME)],

    ?assert(lists:all(WorkersHealthCheck, WorkersPid)),


    grpc:stop_server(?SERVER_NAME),
    ?assertNot(lists:all(WorkersHealthCheck, WorkersPid)),

    _ = grpc_client_sup:stop_channel_pool(?CHANN_NAME),

    ok.
