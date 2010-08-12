% type specification hacked to suppress dialyzer warning re: match spec
-record(shard, {
    name :: binary() | '_',
    node :: node() | '_',
    dbname :: binary(),
    range :: [non_neg_integer() | '$1' | '$2'],
    ref :: reference() | 'undefined' | '_'
}).

%% types
-type join_type() :: init | join | replace | leave.
-type join_order() :: non_neg_integer().
-type options() :: list().
-type mem_node() :: {join_order(), node(), options()}.
-type mem_node_list() :: [mem_node()].
-type arg_options() :: {test, boolean()}.
-type args() :: [] | [arg_options()].
-type test() :: undefined | node().
-type epoch() :: float().
-type clock() :: {node(), epoch()}.
-type vector_clock() :: [clock()].
-type ping_node() :: node() | nil.
-type gossip_fun() :: call | cast.

-type part() :: #shard{}.
-type fullmap() :: [part()].
-type ref_part_map() :: {reference(), part()}.
-type tref() :: reference().
-type np() :: {node(), part()}.
-type beg_acc() :: [integer()].
