% Copyright 2010 Cloudant
%
% Licensed under the Apache License, Version 2.0 (the "License"); you may not
% use this file except in compliance with the License. You may obtain a copy of
% the License at
%
%   http://www.apache.org/licenses/LICENSE-2.0
%
% Unless required by applicable law or agreed to in writing, software
% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
% License for the specific language governing permissions and limitations under
% the License.

-module(fabric_doc_open_revs).

-export([go/4]).

-include("fabric.hrl").
-include_lib("mem3/include/mem3.hrl").
-include_lib("couch/include/couch_db.hrl").
-include_lib("eunit/include/eunit.hrl").

-record(state, {
    dbname,
    worker_count,
    reply_count = 0,
    r,
    revs,
    latest,
    replies = []
}).

go(DbName, Id, Revs, Options) ->
    Workers = fabric_util:submit_jobs(mem3:shards(DbName,Id), open_revs,
        [Id, Revs, Options]),
    R = couch_util:get_value(r, Options, couch_config:get("cluster","r","2")),
    State = #state{
        dbname = DbName,
        worker_count = length(Workers),
        r = list_to_integer(R),
        revs = Revs,
        latest = lists:member(latest, Options),
        replies = case Revs of all -> []; Revs -> [{Rev,[]} || Rev <- Revs] end
    },
    case fabric_util:recv(Workers, #shard.ref, fun handle_message/3, State) of
    {ok, {ok, Reply}} ->
        {ok, Reply};
    Else ->
        Else
    end.

handle_message({rexi_DOWN, _, _, _}, _Worker, State) ->
    skip(State);
handle_message({rexi_EXIT, _}, _Worker, State) ->
    skip(State);
handle_message({ok, RawReplies}, _Worker, #state{revs = all} = State) ->
    #state{
        dbname = DbName,
        reply_count = ReplyCount,
        worker_count = WorkerCount,
        replies = All0,
        r = R
    } = State,
    All = lists:foldl(fun(Reply,D) -> orddict:update_counter(Reply,1,D) end,
        All0, RawReplies),
    Reduced = remove_ancestors(All, []),
    Complete = (ReplyCount =:= (WorkerCount - 1)),
    QuorumMet = lists:all(fun({_, C}) -> C >= R end, Reduced),
    case Reduced of All when QuorumMet andalso ReplyCount =:= (R-1) ->
        Repair = false;
    _ ->
        Repair = [D || {{ok,D}, _} <- Reduced]
    end,
    case maybe_reply(DbName, Reduced, Complete, Repair, R) of
    noreply ->
        {ok, State#state{replies = All, reply_count = ReplyCount+1}};
    {reply, FinalReply} ->
        {stop, FinalReply}
    end;
handle_message({ok, RawReplies0}, _Worker, State) ->
    % we've got an explicit revision list, but if latest=true the workers may
    % return a descendant of the requested revision.  Take advantage of the
    % fact that revisions are returned in order to keep track.
    RawReplies = strip_not_found_missing(RawReplies0),
    #state{
        dbname = DbName,
        reply_count = ReplyCount,
        worker_count = WorkerCount,
        replies = All0,
        r = R
    } = State,
    All = lists:zipwith(fun({Rev, D}, Reply) ->
        if Reply =:= error -> {Rev, D}; true ->
            {Rev, orddict:update_counter(Reply, 1, D)}
        end
    end, All0, RawReplies),
    Reduced = [remove_ancestors(X, []) || {_, X} <- All],
    FinalReplies = [choose_winner(X, R) || X <- Reduced],
    Complete = (ReplyCount =:= (WorkerCount - 1)),
    case is_repair_needed(All, FinalReplies) of
    true ->
        Repair = [D || {{ok,D}, _} <- lists:flatten(Reduced)];
    false ->
        Repair = false
    end,
    case maybe_reply(DbName, FinalReplies, Complete, Repair, R) of
    noreply ->
        {ok, State#state{replies = All, reply_count = ReplyCount+1}};
    {reply, FinalReply} ->
        {stop, FinalReply}
    end.

skip(#state{revs=all} = State) ->
    handle_message({ok, []}, nil, State);
skip(#state{revs=Revs} = State) ->
    handle_message({ok, [error || _Rev <- Revs]}, nil, State).

maybe_reply(_, [], false, _, _) ->
    noreply;
maybe_reply(DbName, ReplyDict, IsComplete, RepairDocs, R) ->
    case lists:all(fun({_, C}) -> C >= R end, ReplyDict) of
    true ->
        maybe_execute_read_repair(DbName, RepairDocs),
        {reply, unstrip_not_found_missing(orddict:fetch_keys(ReplyDict))};
    false ->
        case IsComplete of false -> noreply; true ->
            maybe_execute_read_repair(DbName, RepairDocs),
            {reply, unstrip_not_found_missing(orddict:fetch_keys(ReplyDict))}
        end
    end.

choose_winner(Options, R) ->
    case lists:dropwhile(fun({_Reply, C}) -> C < R end, Options) of
    [] ->
        case [Elem || {{ok, #doc{}}, _} = Elem <- Options] of
        [] ->
            hd(Options);
        Docs ->
            lists:last(lists:sort(Docs))
        end;
    [QuorumMet | _] ->
        QuorumMet
    end.

% repair needed if any reply other than the winner has been received for a rev
is_repair_needed([], []) ->
    false;
is_repair_needed([{_Rev, [Reply]} | Tail1], [Reply | Tail2]) ->
    is_repair_needed(Tail1, Tail2);
is_repair_needed(_, _) ->
    true.

% this presumes the incoming list is sorted, i.e. shorter revlists come first
remove_ancestors([], Acc) ->
    lists:reverse(Acc);
remove_ancestors([{{not_found, _}, Count} = Head | Tail], Acc) ->
    % any document is a descendant
    case lists:filter(fun({{ok, #doc{}}, _}) -> true; (_) -> false end, Tail) of
    [{{ok, #doc{}} = Descendant, _} | _] ->
        remove_ancestors(orddict:update_counter(Descendant, Count, Tail), Acc);
    [] ->
        remove_ancestors(Tail, [Head | Acc])
    end;
remove_ancestors([{{ok, #doc{revs = {Pos, Revs}}}, Count} = Head | Tail], Acc) ->
    Descendants = lists:dropwhile(fun
    ({{ok, #doc{revs = {Pos2, Revs2}}}, _}) ->
        case lists:nthtail(Pos2 - Pos, Revs2) of
        [] ->
            % impossible to tell if Revs2 is a descendant - assume no
            true;
        History ->
            % if Revs2 is a descendant, History is a prefix of Revs
            not lists:prefix(History, Revs)
        end
    end, Tail),
    case Descendants of [] ->
        remove_ancestors(Tail, [Head | Acc]);
    [{Descendant, _} | _] ->
        remove_ancestors(orddict:update_counter(Descendant, Count, Tail), Acc)
    end.

maybe_execute_read_repair(_Db, false) ->
    ok;
maybe_execute_read_repair(Db, Docs) ->
    spawn(fun() ->
        [#doc{id=Id} | _] = Docs,
        Ctx = #user_ctx{roles=[<<"_admin">>]},
        Res = fabric:update_docs(Db, Docs, [replicated_changes, {user_ctx,Ctx}]),
        ?LOG_INFO("read_repair ~s ~s ~p", [Db, Id, Res])
    end).

% hackery required so that not_found sorts first
strip_not_found_missing([]) ->
    [];
strip_not_found_missing([{{not_found, missing}, Rev} | Rest]) ->
    [{not_found, Rev} | strip_not_found_missing(Rest)];
strip_not_found_missing([Else | Rest]) ->
    [Else | strip_not_found_missing(Rest)].

unstrip_not_found_missing([]) ->
    [];
unstrip_not_found_missing([{not_found, Rev} | Rest]) ->
    [{{not_found, missing}, Rev} | unstrip_not_found_missing(Rest)];
unstrip_not_found_missing([Else | Rest]) ->
    [Else | unstrip_not_found_missing(Rest)].

remove_ancestors_test() ->
    Foo1 = {ok, #doc{revs = {1, [<<"foo">>]}}},
    Foo2 = {ok, #doc{revs = {2, [<<"foo2">>, <<"foo">>]}}},
    Bar1 = {ok, #doc{revs = {1, [<<"bar">>]}}},
    Bar2 = {not_found, {1,<<"bar">>}},
    ?assertEqual(
        [{Bar1,1}, {Foo1,1}],
        remove_ancestors([{Bar1,1}, {Foo1,1}], [])
    ),
    ?assertEqual(
        [{Bar1,1}, {Foo2,2}],
        remove_ancestors([{Bar1,1}, {Foo1,1}, {Foo2,1}], [])
    ),
    ?assertEqual(
        [{Bar1,2}],
        remove_ancestors([{Bar2,1}, {Bar1,1}], [])
    ).

all_revs_test() ->
    State0 = #state{worker_count = 3, r = 2, revs = all},
    Foo1 = {ok, #doc{revs = {1, [<<"foo">>]}}},
    Foo2 = {ok, #doc{revs = {2, [<<"foo2">>, <<"foo">>]}}},
    Bar1 = {ok, #doc{revs = {1, [<<"bar">>]}}},

    % an empty worker response does not count as meeting quorum
    ?assertMatch(
        {ok, #state{}},
        handle_message({ok, []}, nil, State0)
    ),

    ?assertMatch(
        {ok, #state{}},
        handle_message({ok, [Foo1, Bar1]}, nil, State0)
    ),
    {ok, State1} = handle_message({ok, [Foo1, Bar1]}, nil, State0),

    % the normal case - workers agree
    ?assertEqual(
        {stop, [Bar1, Foo1]},
        handle_message({ok, [Foo1, Bar1]}, nil, State1)
    ),

    % a case where the 2nd worker has a newer Foo - currently we're considering
    % Foo to have reached quorum and execute_read_repair()
    ?assertEqual(
        {stop, [Bar1, Foo2]},
        handle_message({ok, [Foo2, Bar1]}, nil, State1)
    ),

    % a case where quorum has not yet been reached for Foo
    ?assertMatch(
        {ok, #state{}},
        handle_message({ok, [Bar1]}, nil, State1)
    ),
    {ok, State2} = handle_message({ok, [Bar1]}, nil, State1),

    % still no quorum, but all workers have responded.  We include Foo1 in the
    % response and execute_read_repair()
    ?assertEqual(
        {stop, [Bar1, Foo1]},
        handle_message({ok, [Bar1]}, nil, State2)
    ).

specific_revs_test() ->
    Revs = [{1,<<"foo">>}, {1,<<"bar">>}, {1,<<"baz">>}],
    State0 = #state{
        worker_count = 3,
        r = 2,
        revs = Revs,
        latest = false,
        replies = [{Rev,[]} || Rev <- Revs]
    },
    Foo1 = {ok, #doc{revs = {1, [<<"foo">>]}}},
    Foo2 = {ok, #doc{revs = {2, [<<"foo2">>, <<"foo">>]}}},
    Bar1 = {ok, #doc{revs = {1, [<<"bar">>]}}},
    Baz1 = {{not_found, missing}, {1,<<"baz">>}},
    Baz2 = {ok, #doc{revs = {1, [<<"baz">>]}}},

    ?assertMatch(
        {ok, #state{}},
        handle_message({ok, [Foo1, Bar1, Baz1]}, nil, State0)
    ),
    {ok, State1} = handle_message({ok, [Foo1, Bar1, Baz1]}, nil, State0),

    % the normal case - workers agree
    ?assertEqual(
        {stop, [Foo1, Bar1, Baz1]},
        handle_message({ok, [Foo1, Bar1, Baz1]}, nil, State1)
    ),

    % latest=true, worker responds with Foo2 and we return it
    State0L = State0#state{latest = true},
    ?assertMatch(
        {ok, #state{}},
        handle_message({ok, [Foo2, Bar1, Baz1]}, nil, State0L)
    ),
    {ok, State1L} = handle_message({ok, [Foo2, Bar1, Baz1]}, nil, State0L),
    ?assertEqual(
        {stop, [Foo2, Bar1, Baz1]},
        handle_message({ok, [Foo2, Bar1, Baz1]}, nil, State1L)
    ),

    % Foo1 is included in the read quorum for Foo2
    ?assertEqual(
        {stop, [Foo2, Bar1, Baz1]},
        handle_message({ok, [Foo1, Bar1, Baz1]}, nil, State1L)
    ),

    % {not_found, missing} is included in the quorum for any found revision
    ?assertEqual(
        {stop, [Foo2, Bar1, Baz2]},
        handle_message({ok, [Foo2, Bar1, Baz2]}, nil, State1L)
    ),

    % a worker failure is skipped
    ?assertMatch(
        {ok, #state{}},
        handle_message({rexi_EXIT, foo}, nil, State1L)
    ),
    {ok, State2L} = handle_message({rexi_EXIT, foo}, nil, State1L),
    ?assertEqual(
        {stop, [Foo2, Bar1, Baz2]},
        handle_message({ok, [Foo2, Bar1, Baz2]}, nil, State2L)
    ).
