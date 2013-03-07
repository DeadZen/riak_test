-module(replication2_pg).
-export([confirm/0]).
-include_lib("eunit/include/eunit.hrl").

-import(rt, [deploy_nodes/2,
             join/2,
             wait_until_nodes_ready/1,
             wait_until_no_pending_changes/1]).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Test BNW PG
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
setup_repl_clusters(Conf) ->
    NumNodes = 6,
    lager:info("Deploy ~p nodes", [NumNodes]),

    Nodes = deploy_nodes(NumNodes, Conf),

    lager:info("Nodes = ~p", [Nodes]),
    {[AFirst|_] = ANodes, Rest} = lists:split(2, Nodes),
    {[BFirst|_] = BNodes, [CFirst|_] = CNodes} = lists:split(2, Rest),

    %%AllNodes = ANodes ++ BNodes ++ CNodes,
    rt:log_to_nodes(Nodes, "Starting replication2_pg test"),

    lager:info("ANodes: ~p", [ANodes]),
    lager:info("BNodes: ~p", [BNodes]),
    lager:info("CNodes: ~p", [CNodes]),

    rt:log_to_nodes(Nodes, "Building and connecting clusters"),

    lager:info("Build cluster A"),
    repl_util:make_cluster(ANodes),

    lager:info("Build cluster B"),
    repl_util:make_cluster(BNodes),

    lager:info("Build cluster C"),
    repl_util:make_cluster(CNodes),

    repl_util:name_cluster(AFirst, "A"),
    repl_util:name_cluster(BFirst, "B"),
    repl_util:name_cluster(CFirst, "C"),
    rt:wait_until_ring_converged(ANodes),
    rt:wait_until_ring_converged(BNodes),
    rt:wait_until_ring_converged(CNodes),

    %% get the leader for the first cluster
    repl_util:wait_until_leader(AFirst),
    LeaderA = rpc:call(AFirst, riak_core_cluster_mgr, get_leader, []),

    {ok, {_IP, BPort}} = rpc:call(BFirst, application, get_env,
                                  [riak_core, cluster_mgr]),
    repl_util:connect_cluster(LeaderA, "127.0.0.1", BPort),

    {ok, {_IP, CPort}} = rpc:call(CFirst, application, get_env,
                                  [riak_core, cluster_mgr]),
    repl_util:connect_cluster(LeaderA, "127.0.0.1", CPort),

    ?assertEqual(ok, repl_util:wait_for_connection(LeaderA, "B")),
    rt:wait_until_ring_converged(ANodes),

    ?assertEqual(ok, repl_util:wait_for_connection(LeaderA, "C")),
    rt:wait_until_ring_converged(ANodes),
    {LeaderA, ANodes, BNodes, CNodes, Nodes}.


test_basic_pg() ->
    %%TestHash = erlang:md5(term_to_binary(os:timestamp())),
    %%TestBucket = <<TestHash/binary, "-systest_a">>,

    Conf = [
            {riak_repl,
             [
              {proxy_get, enabled}
             ]}
           ],
    {LeaderA, ANodes, BNodes, _CNodes, AllNodes} =
        setup_repl_clusters(Conf),
    rt:log_to_nodes(AllNodes, "Test without pg enabled"),

    rt:wait_until_ring_converged(ANodes),

    PGEnableResult = rpc:call(LeaderA, riak_repl_console, proxy_get, [["enable","B"]]),
    lager:info("Enabled pg ~p", [PGEnableResult]),
    Status = rpc:call(LeaderA, riak_repl_console, status, [quiet]),

    case proplists:get_value(proxy_get_enabled, Status) of
        undefined -> fail;
        EnabledFor -> lager:info("PG enabled for cluster ~p",[EnabledFor])
    end,

    PidA = rt:pbc(LeaderA),
    {ok,CidA}=riak_repl_pb_api:get_clusterid(PidA),
    lager:info("Cluster ID for A = ~p", [CidA]),
    
    Bucket = <<"test_bucket">>,
    KeyA    = <<"test_key_foo">>,
    ValueA = <<"0b:", "testdata">>,


    Bucket = <<"test_bucket">>,
    KeyB    = <<"test_key_bar">>,
    ValueB = <<"0b:", "testdata">>,
    rt:pbc_write(PidA, Bucket, KeyA, ValueA),
    rt:pbc_write(PidA, Bucket, KeyB, ValueB),

    {_FirstA, FirstB, _FirstC} = get_firsts(AllNodes),
    PidB = rt:pbc(FirstB),
    lager:info("Connected to cluster B"),
    {ok, PGResult} = riak_repl_pb_api:get(PidB,Bucket,KeyA,CidA),
    ?assertEqual(ValueA, riakc_obj:get_value(PGResult)),

    PGDisableResult = rpc:call(LeaderA, riak_repl_console, proxy_get, [["disable","B"]]),
    lager:info("Disable pg ~p", [PGDisableResult]),
    Status2 = rpc:call(LeaderA, riak_repl_console, status, [quiet]),

    case proplists:get_value(proxy_get_enabled, Status2) of
        [] -> ok                 
    end,

    rt:wait_until_ring_converged(ANodes),
    rt:wait_until_ring_converged(BNodes),

    %% After the clusters are disconnected, see if the object was 
    %% written locally after the PG
    {ok, PG2Value} = riak_repl_pb_api:get(PidB,Bucket,KeyA,CidA),
    
    ?assertEqual(ValueA, riakc_obj:get_value(PG2Value)),

    %% test an object that wasn't previously "proxy-gotten", it should fail
    FailedResult = riak_repl_pb_api:get(PidB,Bucket,KeyB,CidA),    
    ?assertEqual({error, notfound}, FailedResult),

    rt:clean_cluster(AllNodes),
    pass.

confirm() ->
    AllTests = [test_basic_pg()],
    case lists:all(fun (Result) -> Result == pass end, AllTests) of
        true ->  pass;
        false -> sadtrombone
    end.

get_firsts(Nodes) ->
    {[AFirst|_] = _ANodes, Rest} = lists:split(2, Nodes),
    {[BFirst|_] = _BNodes, [CFirst|_] = _CNodes} = lists:split(2, Rest),
    {AFirst, BFirst, CFirst}.