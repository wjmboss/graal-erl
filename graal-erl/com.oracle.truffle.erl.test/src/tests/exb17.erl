-module(exb17).
-export([main/0]).

main() ->
	binary_to_term(<<131,116,0,0,0,2,104,0,116,0,0,0,0,106,108,0,0,0,1,97,1,97,2>>).
