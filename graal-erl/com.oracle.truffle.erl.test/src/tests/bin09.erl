-module(bin09).
-export([main/0]).

main() ->
	[
		<<11:5, 22:6>>,
		<<11:5, 22:6, 33:6>>,
		<<11:5, 22:6, 33:6, 44:7, 0:8>>
	].
