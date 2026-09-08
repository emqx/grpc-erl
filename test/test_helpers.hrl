%%--------------------------------------------------------------------
%% Copyright (c) 2023-2026 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-ifndef(TEST_HELPERS_HRL).
-define(TEST_HELPERS_HRL, true).

-define(drainMailbox(), ?drainMailbox(0)).
-define(drainMailbox(TIMEOUT),
    (fun F__Flush_() ->
        receive
            X__Msg_ -> [X__Msg_ | F__Flush_()]
        after TIMEOUT -> []
        end
    end)()
).

-define(assertReceive(PATTERN),
    ?assertReceive(PATTERN, 1000)
).

-define(assertReceive(PATTERN, TIMEOUT),
    ?assertReceive(PATTERN, TIMEOUT, #{})
).

-define(assertReceive(PATTERN, TIMEOUT, EXTRA),
    (fun() ->
        receive
            X__V = PATTERN -> X__V
        after TIMEOUT ->
            erlang:error(
                {assertReceive, [
                    {module, ?MODULE},
                    {line, ?LINE},
                    {expression, (??PATTERN)},
                    {mailbox, ?drainMailbox()},
                    {extra_info, EXTRA}
                ]}
            )
        end
    end)()
).

-define(assertNotReceive(PATTERN),
    ?assertNotReceive(PATTERN, 300, undefined)
).

-define(assertNotReceive(PATTERN, TIMEOUT),
    ?assertNotReceive(PATTERN, TIMEOUT, undefined)
).

-define(assertNotReceive(PATTERN, TIMEOUT, COMMENT),
    (fun() ->
        receive
            X__V = PATTERN ->
                erlang:error(
                    {assertNotReceive, [
                        {module, ?MODULE},
                        {line, ?LINE},
                        {expression, (??PATTERN)},
                        {message, X__V},
                        {comment, COMMENT}
                    ]}
                )
        after TIMEOUT ->
            ok
        end
    end)()
).

-endif.
