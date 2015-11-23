-module(parser).
-export([parse/1, ast/1, ast/2, ast/3, gen_ast/1, scan/1, scan_forms/1]).

scan(FileName) ->
	{ok, File} = file:read_file(FileName),
	{ok, Tokens, _} = erl_scan:string(binary_to_list(File)),
	Tokens.

scan_forms(FileName) ->
	{ok, File} = file:read_file(FileName),
	scan_forms(FileName, unicode:characters_to_list(File, utf8)).
	%scan_forms(FileName, binary_to_list(File)).

scan_forms(_, Data) ->
	scan_forms_impl(erl_scan:tokens([], Data, 1, []), []).

scan_forms_impl({done, {ok, T, N}, S}, Res) ->
	scan_forms_impl(erl_scan:tokens([], S, N, []), [T | Res]);
scan_forms_impl(_, Res) ->
	lists:reverse(Res).

gen_ast([]) ->
	ok;
gen_ast([ModuleName, AstFileName, SourceFileName | Tail]) ->
	ast(ModuleName, AstFileName, SourceFileName),
	gen_ast(Tail).

ast(ModuleName) when is_atom(ModuleName) ->
	ast(ModuleName, atom_to_list(ModuleName) ++ ".ast");
ast(ModuleName) ->
	ast(list_to_atom(ModuleName), ModuleName ++ ".ast").

ast(ModuleName, AstFileName) when is_atom(ModuleName) ->
	ast(ModuleName, AstFileName, atom_to_list(ModuleName) ++ ".erl");
ast(ModuleName, AstFileName) ->
	ast(list_to_atom(ModuleName), AstFileName, ModuleName ++ ".erl").

ast(ModuleName, AstFileName, SourceFileName) when is_atom(ModuleName) ->
	{AST, State} = parse(SourceFileName),
	Imports = maps:get(imports, State, []),
	file:write_file(AstFileName, io_lib:format("~w\n~w\n~p\n", [ModuleName, Imports, AST]));
ast(ModuleName, AstFileName, SourceFileName) ->
	ast(list_to_atom(ModuleName), AstFileName, SourceFileName).

parse(FileName) when is_atom(FileName) ->
	parse(atom_to_list(FileName) ++ ".erl");
parse(FileName) ->
	Forms = scan_forms(FileName),
	%file:write_file("/tmp/forms", io_lib:format("~p~n", [Forms])),
	case init:get_argument(include) of
		{ok, ListOfListOfString} -> ArgInclude = pack1(ListOfListOfString);
		error                    -> ArgInclude = []
	end,
	DirName = filename:dirname(FileName),
	InitialState =
	#{
		active  => [true],
		lib_dir => code:lib_dir(),
		include => [".", DirName, DirName ++ "/../include/" | ArgInclude]
	},
	%io:format("InitialState = ~p~n", [InitialState]),
	preprocess_and_parse([], Forms, InitialState).

parse_and_extract_form(Form) ->
	% io:format("form: ~p~n", [Form]),
	case erl_parse:parse_form(Form) of
		{ok, ParsedForm} ->
			ParsedForm;
		{error, {Line, _, Problem}} ->
			io:format("Line: ~p~nProblem: ~p~nForm: ~p~n", [Line, Problem, Form]),
			erlang:throw(parse_error)
	end.

preprocess_and_parse(RevAcc, [[{'-', _} | RestOfForm] | Tail], State) ->
	% we found a '-' symbol, which is a directive, try to read it
	{ok, [Active|_]} = maps:find(active, State),
	{ok, ReadAttributes, Remaining} = read_attribute(preprocess([], RestOfForm, State, soft), Tail, Active, State),
	continue_preprocess_and_parse(RevAcc, Remaining, ReadAttributes, State);
preprocess_and_parse(RevAcc, [Head | Tail], State) ->
	% we found a form, preprocess, and parse it
	{ok, [Active|_]} = maps:find(active, State),
	case Active of
		true  -> preprocess_and_parse([parse_and_extract_form(preprocess([], Head, State, hard)) | RevAcc], Tail, State);
		false -> preprocess_and_parse(RevAcc, Tail, State)
	end;
preprocess_and_parse(RevAcc, [], State) ->
	{lists:reverse(RevAcc), State}.

preprocess(RevAcc, Tokens, State, Mode) ->
	preprocess_impl(RevAcc, Tokens, State, lk_initial(), Mode).

preprocess_impl(RevAcc, [{'?', _}, {Type, Line, Name} | MoreTokens], State, LocKind, Mode) when atom==Type; var==Type ->
	{ok,  Resolved, RestTokens} = resolve(Name, Line, MoreTokens, State, Mode),
	case Mode of
		hard -> preprocess_impl(RevAcc, lists:append(lists:reverse(Resolved), RestTokens), State, LocKind, Mode);
		soft -> preprocess_impl(lists:append(Resolved, RevAcc), RestTokens, State, LocKind, Mode);
		_    -> {error, unknown_mode, Mode}
	end;
preprocess_impl(RevAcc, [{'#', _}, {atom, Line, RecName}, {'{', _} | MoreTokens], State, LocKind, Mode) ->
	% record expression or record update
	case head_is_end_of_expr(RevAcc) of
		true ->
			{Expr, NewRevAcc} = fetch_last_expr(RevAcc),
			{ok, Replacement, RestTokens} = resolve_record_update(RecName, Expr, Line, MoreTokens, State);
		false ->
			NewRevAcc = RevAcc,
			PatternPositionHint = lk_pattern_position_hint(LocKind),
			{ok, Replacement, RestTokens} = resolve_record_expr(RecName, Line, MoreTokens, PatternPositionHint, State)
	end,
	preprocess_impl(lists:append(Replacement, NewRevAcc), RestTokens, State, LocKind, Mode);
preprocess_impl(RevAcc, [{'#', _}, {atom, Line, RecName}, {'.', _}, {atom, _, Field} | MoreTokens], State, LocKind, Mode) ->
	% record field access
	{Expr, NewRevAcc} = fetch_last_expr(RevAcc),
	RestTokens = MoreTokens,
	Replacement = resolve_record_fieldaccess(RecName, Expr, Line, Field, State),
	preprocess_impl(lists:append(Replacement, NewRevAcc), RestTokens, State, LocKind, Mode);
preprocess_impl(RevAcc, [T1={Type, _, _}, T2={'(', _} | MoreTokens], State, LocKind, Mode) ->
	case Type of
		var  -> NewLocKind = lk_call(LocKind);
		atom -> NewLocKind = lk_call(LocKind);
		_    -> NewLocKind = lk_token(LocKind, '(')
	end,
	preprocess_impl([T2, T1 | RevAcc], MoreTokens, State, NewLocKind, Mode);
preprocess_impl(RevAcc, [Token | MoreTokens], State, LocKind, Mode) ->
	case Token of
		{T, _} -> NewLocKind = lk_token(LocKind, T);
		_      -> NewLocKind = LocKind
	end,
	preprocess_impl([Token | RevAcc], MoreTokens, State, NewLocKind, Mode);
preprocess_impl(RevAcc, [], _State, _LocKind, _Mode) ->
	lists:reverse(RevAcc).

continue_preprocess_and_parse(RevAcc, Forms, [{macro, MacroName, MacroDef} | Tail], State) ->
	% simple macro attribute found
	Macros = maps:get(macros, State, #{}),
	continue_preprocess_and_parse(RevAcc, Forms, Tail, State#{macros => Macros#{MacroName => MacroDef}});
continue_preprocess_and_parse(RevAcc, Forms, [{parametric, MacroName, MacroArgs, MacroDef} | Tail], State) ->
	% parametric macro attribute found
	Parametrics = maps:get(parametrics, State, #{}),
	Overloads = maps:get(MacroName, Parametrics, #{}),
	Arity = length(MacroArgs),
	continue_preprocess_and_parse(RevAcc, Forms, Tail, State#{parametrics => Parametrics#{MacroName => Overloads#{Arity => {MacroArgs, MacroDef}}}});
continue_preprocess_and_parse(RevAcc, Forms, [{import, ImportModuleName, ImportFAs} | Tail], State) ->
	% import attribute found
	Imports = maps:get(imports, State, []),
	NewImports = register_imports(Imports, ImportModuleName, ImportFAs),
	continue_preprocess_and_parse(RevAcc, Forms, Tail, State#{imports => NewImports});
continue_preprocess_and_parse(RevAcc, Forms, [{record, RecordName, RecordInfo} | Tail], State) ->
	% record attribute found
	Records = maps:get(records, State, #{}),
	continue_preprocess_and_parse(RevAcc, Forms, Tail, State#{records => Records#{RecordName => RecordInfo}});
continue_preprocess_and_parse(RevAcc, Forms, [{ifdef, Active} | Tail], State) ->
	% control flow attribute found
	{ok, ActiveStack} = maps:find(active, State),
	continue_preprocess_and_parse(RevAcc, Forms, Tail, State#{active => [Active | ActiveStack]});
continue_preprocess_and_parse(RevAcc, Forms, [{else} | Tail], State) ->
	{ok, [H1,H2|ActiveTail]} = maps:find(active, State),
	continue_preprocess_and_parse(RevAcc, Forms, Tail, State#{active => [(H2 and not H1),H2|ActiveTail]});
continue_preprocess_and_parse(RevAcc, Forms, [{endif} | Tail], State) ->
	{ok, [_|ActiveTail]} = maps:find(active, State),
	continue_preprocess_and_parse(RevAcc, Forms, Tail, State#{active => ActiveTail});
continue_preprocess_and_parse(RevAcc, Forms, [], State) ->
	% no unprocessed attribute left
	preprocess_and_parse(RevAcc, Forms, State).

register_imports(ImportList, ImportModuleName, [{FuncName, Arity} | FAs]) ->
	register_imports([{ImportModuleName, FuncName, Arity}|ImportList], ImportModuleName, FAs);
register_imports(ImportList, _ImportModuleName, []) ->
	ImportList.

head_is_end_of_expr([Head | _Tail]) ->
	case Head of
		{')', _}    -> true;
		{'}', _}    -> true;
		{']', _}    -> true;
		{var, _, _} -> true;
		_           -> false
	end;
head_is_end_of_expr(_) ->
	false.

fetch_last_expr(RevExprs) ->
	{Expr, RevTail} = fetch_last_expr([], RevExprs),
	{lists:reverse(Expr), RevTail}.

fetch_last_expr(Acc, [Head={Close, _} | Tail]) ->
	case Close of
		')' -> fetch_last_expr_impl([Head | Acc], Tail, 0, '(', ')', fun fetch_paren_head/2);
		'}' -> fetch_last_expr_impl([Head | Acc], Tail, 0, '{', '}', fun fetch_brace_head/2);
		']' -> fetch_last_expr_impl([Head | Acc], Tail, 0, '[', ']', undefined)
	end;
fetch_last_expr(Acc, [Head={var, _, _} | Tail]) ->
	{[Head | Acc], Tail}.

fetch_paren_head(Acc, [H1={atom, _, _}, H2={':', _}, H3={atom, _, _} | Tail]) ->
	% remote function call
	{[H3, H2, H1 | Acc], Tail};
fetch_paren_head(Acc, [H1={Type, _, _} | Tail]) when atom==Type; var==Type ->
	% local function call, or fun variable
	{[H1 | Acc], Tail};
fetch_paren_head(Acc, Tail) ->
	% simple parenthesis
	{Acc, Tail}.

fetch_brace_head(Acc, [H1={'#', _} | Tail]) ->
	case head_is_end_of_expr(Tail) of
		true -> fetch_last_expr([H1 | Acc], Tail);
		_    -> {[H1 | Acc], Tail}
	end;
fetch_brace_head(Acc, Tail) ->
	% tuple
	{Acc, Tail}.

fetch_last_expr_impl(Acc, [Head={Open, _} | Tail], 0, Open, _Close, Fun) ->
	case is_function(Fun) of
		true -> Fun([Head | Acc], Tail);
		_    -> {[Head | Acc], Tail}
	end;
fetch_last_expr_impl(Acc, [Head={Open, _} | Tail], Depth, Open, Close, Fun) ->
	fetch_last_expr_impl([Head | Acc], Tail, Depth+1, Open, Close, Fun);
fetch_last_expr_impl(Acc, [Head={Close, _} | Tail], Depth, Open, Close, Fun) ->
	fetch_last_expr_impl([Head | Acc], Tail, Depth-1, Open, Close, Fun);
fetch_last_expr_impl(Acc, [Head | Tail], Depth, Open, Close, Fun) ->
	fetch_last_expr_impl([Head | Acc], Tail, Depth, Open, Close, Fun).

resolve('LINE', Line, RestTokens, _State, _Mode) ->
	{ok, [{integer, Line, Line}], RestTokens};
resolve(NameToResolve, Line, RestTokens, State, Mode) ->
	{RMC, RMR} = resolve_macro(NameToResolve, RestTokens, State),
	case RMC of
		ok -> RMR;
		_  ->
			{RPC, RPR} = resolve_parametric(NameToResolve, RestTokens, State),
			case RPC of
				ok -> RPR;
				_  ->
					case Mode of
						soft -> {ok, [{var, Line, NameToResolve}, {'?', Line}], RestTokens};
						hard -> {error, {no_such_macro, NameToResolve, Line}}
					end
			end
	end.

resolve_macro(NameToResolve, RestTokens, State) ->
	case maps:find(macros, State) of
		{ok, Macros} ->
			case maps:find(NameToResolve, Macros) of
				{ok, Replacement} -> {ok, {ok, Replacement, RestTokens}};
				_ -> {error, RestTokens}
			end;
		error ->
			{error, RestTokens}
	end.

resolve_parametric(NameToResolve, RestTokens, State) ->
	case maps:find(parametrics, State) of
		{ok, Parametrics} ->
			case maps:find(NameToResolve, Parametrics) of
				{ok, Overloads} -> collect_parametric_params(NameToResolve, Overloads, RestTokens);
				_ -> {error, RestTokens}
			end;
		error ->
			{error, RestTokens}
	end.

collect_parametric_params(MacroName, Overloads, [{'(', _} | RestTokens]) ->
	collect_parametric_params(MacroName, Overloads, [], [], 0, RestTokens).

collect_parametric_params(MacroName, Overloads, Actuals, Acc, 0=_Level, [{',', _} | RestTokens]) ->
	collect_parametric_params(MacroName, Overloads, [Acc | Actuals], [], 0, RestTokens);
collect_parametric_params(MacroName, Overloads, Actuals, Acc, 0=_Level, [{')', _} | RestTokens]) ->
	NewActuals = build_actual_macro_params(Acc, Actuals),
	ActualArity = length(NewActuals),
	case maps:find(ActualArity, Overloads) of
		{ok, {MacroParamNames, MacroReplacement}} ->
			ParamMap = build_param_map(MacroParamNames, NewActuals),
			replace_parametric_macro(ParamMap, [], MacroReplacement, RestTokens);
		_ -> {error, no_overload_found, MacroName, ActualArity}
	end;
collect_parametric_params(MacroName, Overloads, Actuals, Acc, Level, [Token={Tok, _} | RestTokens]) ->
	NewLevel = new_level(Level, Tok),
	collect_parametric_params(MacroName, Overloads, Actuals, [Token | Acc], NewLevel, RestTokens);
collect_parametric_params(MacroName, Overloads, Actuals, Acc, Level, [Token | RestTokens]) ->
	collect_parametric_params(MacroName, Overloads, Actuals, [Token | Acc], Level, RestTokens).

replace_parametric_macro(ParamMap, Acc, [Tok={var, _, Var} | RepTokens], RestTokens) ->
	case maps:find(Var, ParamMap) of
		{ok, ParamValue} -> replace_parametric_macro(ParamMap, ParamValue ++ Acc, RepTokens, RestTokens);
		_                -> replace_parametric_macro(ParamMap, [Tok | Acc], RepTokens, RestTokens)
	end;
replace_parametric_macro(ParamMap, Acc, [RepToken | RepTokens], RestTokens) ->
	replace_parametric_macro(ParamMap, [RepToken | Acc], RepTokens, RestTokens);
replace_parametric_macro(_ParamMap, Acc, [], RestTokens) ->
	%io:format("RPM: ~p, ~p~n", [Acc, RestTokens]),
	{ok, {ok, Acc, RestTokens}}.

build_param_map(Names, Values) ->
	build_param_map(#{}, Names, Values).

build_param_map(Map, [Name|Names], [Value|Values]) ->
	build_param_map(Map#{Name => Value}, Names, Values);
build_param_map(Map, [], []) ->
	Map.

build_actual_macro_params([], []) ->
	[];
build_actual_macro_params([], Actuals) ->
	lists:reverse(Actuals);
build_actual_macro_params(Acc, Actuals) ->
	lists:reverse([Acc | Actuals]).

read_attribute([{atom, _, file}, {'(', _} | _], Forms, _Active, _State) ->
	{ok, [], Forms};
read_attribute([{atom, _, module}, {'(', _}, {atom, _, ModuleName}, {')', _}, {dot, _} | []], Forms, _Active, _State) ->
	% module name has a strict syntax (we do not match the module name and the file name)
	{ok, [{macro, 'MODULE', [{atom, -1, ModuleName}]}, {macro, 'MODULE_STRING', [{string, -1, atom_to_list(ModuleName)}]}], Forms};
read_attribute([{atom, Line, define}, {'(', _}, {Type, _, DefName}, {',', _} | DefTail], Forms, Active, _State) when atom==Type; var==Type ->
	% defining simple macros
	case Active of
		true  -> parse_simple_macro(DefName, Line, DefTail, Forms);
		false -> {ok, [], Forms}
	end;
read_attribute([{atom, Line, define}, {'(', _}, {Type, _, DefName}, {'(', _} | DefTail], Forms, Active, _State) when atom==Type; var==Type ->
	% defining parametric macros
	case Active of
		true  -> parse_parametric_macro(DefName, Line, DefTail, Forms);
		false -> {ok, [], Forms}
	end;
read_attribute([{atom, _, record}, {'(', _}, {atom, _, RecName}, {',', _}, {'{', _} | Tail], Forms, Active, _State) ->
	% defining record (will be translated)
	case Active of
		true  -> parse_record(RecName, Tail, Forms);
		false -> {ok, [], Forms}
	end;
read_attribute([{atom, _, export} | _], Forms, _Active, _State) ->
	% drop the 'export' now, we don't need it yet
	{ok, [], Forms};
read_attribute([{atom, _, export_type} | _], Forms, _Active, _State) ->
	% drop the 'export_type' now, we don't need it yet
	{ok, [], Forms};
read_attribute([{atom, _, type} | _], Forms, _Active, _State) ->
	% drop the 'type' now, we don't need it yet
	{ok, [], Forms};
read_attribute([{atom, _, opaque} | _], Forms, _Active, _State) ->
	% drop the 'opaque' now, we don't need it yet
	{ok, [], Forms};
read_attribute([{atom, _, import} | Rest], Forms, Active, _State) ->
	% parse the import attribute
	case Active of
		true  -> parse_imports(Rest, Forms);
		false -> {ok, [], Forms}
	end;
read_attribute([{atom, _, include}, {'(', _}, {string, _, Filename}, {')', _}, {dot, _}], Forms, Active, State) ->
	% parse the include attribute
	case Active of
		true  -> parse_include(Filename, Forms, State);
		false -> {ok, [], Forms}
	end;
read_attribute([{atom, _, include_lib}, {'(', _}, {string, _, Filename}, {')', _}, {dot, _}], Forms, Active, State) ->
	% parse the include attribute
	case Active of
		true  -> parse_include_lib(Filename, Forms, State);
		false -> {ok, [], Forms}
	end;
read_attribute([{atom, _, compile} | _], Forms, _Active, _State) ->
	% drop the 'compile' now, we don't need it yet
	{ok, [], Forms};
read_attribute([{atom, _, spec} | _], Forms, _Active, _State) ->
	% drop the 'spec' now, we don't need it yet
	{ok, [], Forms};
read_attribute([{atom, _, deprecated} | _], Forms, _Active, _State) ->
	% drop the 'deprecated' now, we don't need it yet
	{ok, [], Forms};
read_attribute([{atom, _, ifdef}, {'(', _}, {Type, _, MacroName}, {')', _}, {dot, _}], Forms, Active, State) when atom==Type; var==Type ->
	Defined = is_macro_defined(State, MacroName),
	{ok, [{ifdef, Active and Defined}], Forms};
read_attribute([{atom, _, ifndef}, {'(', _}, {Type, _, MacroName}, {')', _}, {dot, _}], Forms, Active, State) when atom==Type; var==Type ->
	Defined = is_macro_defined(State, MacroName),
	{ok, [{ifdef, Active and not Defined}], Forms};
read_attribute([{atom, _, else} | _], Forms, _Active, _State) ->
	{ok, [{else}], Forms};
read_attribute([{atom, _, endif} | _], Forms, _Active, _State) ->
	{ok, [{endif}], Forms};
read_attribute([{atom, Line, AtomName} | _Rest], _Forms, _Active, _State) ->
	% not supported feature
	io:format("rest: ~p~n", [_Rest]),
	{error, {unknown_attribute, Line, AtomName}};
read_attribute(_, _Forms, _Active, _State) ->
	% we expect at least an atom here
	{error, {expected_an_atom}}.

parse_simple_macro(DefName, Line, Tail, Forms) ->
	%InitialAcc = [{'(', Line}],
	InitialAcc = [],
	parse_simple_macro(DefName, Line, 0, InitialAcc, Tail, Forms).

parse_simple_macro(DefName, Line, 0, Acc, [Head={',', _} | Tail], Forms) ->
	%NewAcc = [{'(', Line}, Head, {')', Line} | Acc],
	NewAcc = [Head | Acc],
	parse_simple_macro(DefName, Line, 0, NewAcc, Tail, Forms);
parse_simple_macro(DefName, _Line, 0, Acc, [_Head={')', _}, {dot, _}], Forms) ->
	%NewAcc = [Head | Acc],
	NewAcc = Acc,
	{ok, [{macro, DefName, NewAcc}], Forms};
parse_simple_macro(DefName, Line, Depth, Acc, [Head={Tok, _} | Tail], Forms) ->
	NewDepth = new_level(Depth, Tok),
	parse_simple_macro(DefName, Line, NewDepth, [Head | Acc], Tail, Forms);
parse_simple_macro(DefName, Line, Depth, Acc, [Head | Tail], Forms) ->
	parse_simple_macro(DefName, Line, Depth, [Head | Acc], Tail, Forms);
parse_simple_macro(DefName, Line, _Depth, _Acc, _Tail, _Forms) ->
	{error, {illformed_simple_macro, DefName, line, Line}}.

parse_parametric_macro(DefName, Line, DefTail, Forms) ->
	parse_parametric_macro(DefName, [], Line, DefTail, Forms).

parse_parametric_macro(DefName, RevArgs, Line, [{var, _, ArgName}, {',', _} | DefTail], Forms) ->
	parse_parametric_macro(DefName, [ArgName | RevArgs], Line, DefTail, Forms);
parse_parametric_macro(DefName, RevArgs, Line, [{var, _, ArgName}, {')', _}, {',', _} | DefTail], Forms) ->
	%InitialAcc = [{'(', Line}],
	InitialAcc = [],
	parse_parametric_macro_tail(DefName, lists:reverse([ArgName | RevArgs]), Line, 0, InitialAcc, DefTail, Forms).

parse_parametric_macro_tail(DefName, Args, Line, 0, Acc, [Head={',', _} | Tail], Forms) ->
	%NewAcc = [{'(', Line}, Head, {')', Line} | Acc],
	NewAcc = [Head | Acc],
	parse_parametric_macro_tail(DefName, Args, Line, 0, NewAcc, Tail, Forms);
parse_parametric_macro_tail(DefName, Args, _Line, 0, Acc, [_Head={')', _}, {dot, _}], Forms) ->
	%NewAcc = [Head | Acc],
	NewAcc = Acc,
	{ok, [{parametric, DefName, Args, lists:reverse(NewAcc)}], Forms};
parse_parametric_macro_tail(DefName, Args, Line, Depth, Acc, [Head={Tok, _} | Tail], Forms) ->
	NewDepth = new_level(Depth, Tok),
	parse_parametric_macro_tail(DefName, Args, Line, NewDepth, [Head | Acc], Tail, Forms);
parse_parametric_macro_tail(DefName, Args, Line, Depth, Acc, [Head={var, _, _VarName} | Tail], Forms) ->
	%case list_contains(Args, VarName) of
	%	true  -> NewAcc = [{')', Line}, Head, {'(', Line} | Acc];
	%	false -> NewAcc = [Head | Acc]
	%end,
	NewAcc = [Head | Acc],
	parse_parametric_macro_tail(DefName, Args, Line, Depth, NewAcc, Tail, Forms);
parse_parametric_macro_tail(DefName, Args, Line, Depth, Acc, [Head | Tail], Forms) ->
	parse_parametric_macro_tail(DefName, Args, Line, Depth, [Head | Acc], Tail, Forms);
parse_parametric_macro_tail(DefName, _Args, Line, _Depth, _Acc, _Tail, _Forms) ->
	{error, {illformed_parametric_macro, DefName, line, Line}}.

parse_imports([{'(', _}, {atom, _, ModuleName}, {',', _}, {'[', _} | Rest], Forms) ->
	parse_imports(ModuleName, Rest, [], Forms).

parse_imports(ModuleName, [{atom, _, Func}, {'/', _}, {integer, _, Arity} | Rest], FAs, Forms) ->
	parse_imports(ModuleName, Rest, [{Func, Arity} | FAs], Forms);
parse_imports(ModuleName, [{',', _} | Rest], FAs, Forms) ->
	parse_imports(ModuleName, Rest, FAs, Forms);
parse_imports(ModuleName, [{']', _}, {')', _}, {dot, _}], FAs, Forms) ->
	{ok, [{import, ModuleName, FAs}], Forms}.

parse_record(RecName, Tail, Forms) ->
	parse_record(RecName, #{}, [], 2, Tail, Forms).

parse_record(RecName, FieldMap, FieldList, NextFieldId, [{atom, _, Field}, {',', _} | Tail], Forms) ->
	parse_record(RecName, FieldMap#{Field => {NextFieldId, undefined}}, [Field | FieldList], NextFieldId+1, Tail, Forms);
parse_record(RecName, FieldMap, FieldList, NextFieldId, [{atom, _, Field}, {'=', _} | Tail], Forms) ->
	parse_record_with_initial(RecName, FieldMap, FieldList, NextFieldId, Field, Tail, Forms);
parse_record(RecName, FieldMap, FieldList, NextFieldId, [{atom, _, Field}, {'::', _} | Tail], Forms) ->
	parse_record_drop_type_spec(RecName, FieldMap#{Field => {NextFieldId, undefined}}, [Field | FieldList], NextFieldId+1, Tail, Forms);
parse_record(RecName, FieldMap, FieldList, NextFieldId, [{atom, _, Field}, {'}', _} | Tail], Forms) ->
	build_record_info(RecName, FieldMap#{Field => {NextFieldId, undefined}}, [Field | FieldList], NextFieldId, Tail, Forms).

parse_record_with_initial(RecName, FieldMap, FieldList, NextFieldId, Field, Tail, Forms) ->
	parse_record_with_initial(RecName, FieldMap, FieldList, NextFieldId, Field, 0, [{'(', -1}], Tail, Forms).

parse_record_with_initial(RecName, FieldMap, FieldList, NextFieldId, Field, 0, Initial, [{',', _} | Tail], Forms) ->
	parse_record(RecName, FieldMap#{Field => {NextFieldId, [{')', -1} | Initial]}}, [Field | FieldList], NextFieldId+1, Tail, Forms);
parse_record_with_initial(RecName, FieldMap, FieldList, NextFieldId, Field, 0, Initial, [{'::', _} | Tail], Forms) ->
	parse_record_drop_type_spec(RecName, FieldMap#{Field => {NextFieldId, [{')', -1} | Initial]}}, [Field | FieldList], NextFieldId+1, Tail, Forms);
parse_record_with_initial(RecName, FieldMap, FieldList, NextFieldId, Field, 0, Initial, [{'}', _} | Tail], Forms) ->
	build_record_info(RecName, FieldMap#{Field => {NextFieldId, [{')', -1} | Initial]}}, [Field | FieldList], NextFieldId, Tail, Forms);
parse_record_with_initial(RecName, FieldMap, FieldList, NextFieldId, Field, Depth, Initial, [Head={Tok, _} | Tail], Forms) ->
	NewDepth = new_level(Depth, Tok),
	parse_record_with_initial(RecName, FieldMap, FieldList, NextFieldId, Field, NewDepth, [Head | Initial], Tail, Forms);
parse_record_with_initial(RecName, FieldMap, FieldList, NextFieldId, Field, Depth, Initial, [Head | Tail], Forms) ->
	parse_record_with_initial(RecName, FieldMap, FieldList, NextFieldId, Field, Depth, [Head | Initial], Tail, Forms).

parse_record_drop_type_spec(RecName, FieldMap, FieldList, NextFieldId, Tail, Forms) ->
	parse_record_drop_type_spec(RecName, FieldMap, FieldList, NextFieldId, 0, Tail, Forms).

parse_record_drop_type_spec(RecName, FieldMap, FieldList, NextFieldId, 0, [{',', _} | Tail], Forms) ->
	parse_record(RecName, FieldMap, FieldList, NextFieldId, Tail, Forms);
parse_record_drop_type_spec(RecName, FieldMap, FieldList, NextFieldId, 0, [{'}', _} | Tail], Forms) ->
	build_record_info(RecName, FieldMap, FieldList, NextFieldId, Tail, Forms);
parse_record_drop_type_spec(RecName, FieldMap, FieldList, NextFieldId, Depth, [{Tok, _} | Tail], Forms) ->
	NewDepth = new_level(Depth, Tok),
	parse_record_drop_type_spec(RecName, FieldMap, FieldList, NextFieldId, NewDepth, Tail, Forms);
parse_record_drop_type_spec(RecName, FieldMap, FieldList, NextFieldId, Depth, [_Head | Tail], Forms) ->
	parse_record_drop_type_spec(RecName, FieldMap, FieldList, NextFieldId, Depth, Tail, Forms).

build_record_info(RecName, FieldMap, FieldList, Size, [{')', _}, {dot, _}], Forms) ->
	{ok, [{record, RecName, {RecName, Size, FieldMap, FieldList}}], Forms}.

is_macro_defined(State, MacroName) ->
	is_macro_defined_in(
		[
			maps:find(macros, State),
			maps:find(parametrics, State)
		],
		MacroName).

is_macro_defined_in([{ok, Map} | Tail], MacroName) ->
	case maps:is_key(MacroName, Map) of
		true  -> true;
		false -> is_macro_defined_in(Tail, MacroName)
	end;
is_macro_defined_in([_ | Tail], MacroName) ->
	is_macro_defined_in(Tail, MacroName);
is_macro_defined_in([], _MacroName) ->
	false.

resolve_record_update(RecName, Expr, Line, MoreTokens, State) ->
	{ok, Records} = maps:find(records, State),
	{ok, {RecName, _Size, FieldMap, _FieldList}} = maps:find(RecName, Records),
	resolve_record_update_impl(Expr, Line, [], FieldMap, MoreTokens).

resolve_record_update_impl(Expr, _Line, _ModifiedFields, _FieldMap, [{'}', _} | RestTokens]) ->
	{ok, Expr, RestTokens};
resolve_record_update_impl(Expr, Line, ModifiedFields, FieldMap, [{atom, _, Field}, {'=', _} | MoreTokens]) ->
	{ValueExpr, MoreTokens2} = parse_record_field_assign(MoreTokens),
	{ok, {FieldId, _Initial}} = maps:find(Field, FieldMap),
	SetElementExpr = make_setelement_expr(FieldId, Expr, ValueExpr, Line),
	resolve_record_update_impl(SetElementExpr, Line, [Field | ModifiedFields], FieldMap, MoreTokens2).

resolve_record_fieldaccess(RecName, Expr, Line, Field, State) ->
	{ok, Records} = maps:find(records, State),
	{ok, {RecName, _Size, FieldMap, _FieldList}} = maps:find(RecName, Records),
	{ok, {FieldId, _Initial}} = maps:find(Field, FieldMap),
	make_getelement_expr(FieldId, Expr, Line).

resolve_record_expr(RecName, Line, MoreTokens, PatternHint, State) ->
	Records = maps:get(records, State, #{}),
	{ok, RecordInfo={RecName, _Size, _FieldMap, _FieldList}} = maps:find(RecName, Records),
	resolve_record_expr(RecName, RecordInfo, Line, #{}, MoreTokens, PatternHint).

resolve_record_expr(RecName, RecordInfo, Line, FieldAssigns, [{'}', _} | RestTokens], PatternHint) ->
	{RecName, _Size, FieldMap, FieldList} = RecordInfo,
	IsPattern = lk_update_hint(PatternHint, RestTokens),
	case IsPattern of
		true  -> FinalAssigns = FieldAssigns;
		false -> FinalAssigns = maps:merge(FieldMap, FieldAssigns)
	end,
	{ok, make_tuple_from_record(RecName, FieldList, FinalAssigns, Line, IsPattern), RestTokens};
resolve_record_expr(RecName, RecordInfo, Line, FieldAssigns, [{atom, _, Field}, {'=', _} | MoreTokens], PatternHint) ->
	{Expr, MoreTokens2} = parse_record_field_assign(MoreTokens),
	resolve_record_expr(RecName, RecordInfo, Line, FieldAssigns#{Field => Expr}, MoreTokens2, PatternHint);
resolve_record_expr(RecName, RecordInfo, Line, FieldAssigns, [{var, _, '_'}, {'=', _} | MoreTokens], PatternHint) ->
	{Expr, MoreTokens2} = parse_record_field_assign(MoreTokens),
	{RecName, _Size, _FieldMap, FieldList} = RecordInfo,
	NewFieldAssigns = fill_remaining_field_assigns(FieldAssigns, FieldList, Expr),
	resolve_record_expr(RecName, RecordInfo, Line, NewFieldAssigns, MoreTokens2, PatternHint).

parse_record_field_assign(Tokens) ->
	parse_record_field_assign([], 0, Tokens).

parse_record_field_assign(Acc, 0, [{',', _} | RestTokens]) ->
	{Acc, RestTokens};
parse_record_field_assign(Acc, 0, [{'}', _} | _] = RestTokens) ->
	{Acc, RestTokens};
parse_record_field_assign(Acc, Level, [Token={Tok, _} | Tokens]) ->
	NewLevel = new_level(Level, Tok),
	parse_record_field_assign([Token | Acc], NewLevel, Tokens);
parse_record_field_assign(Acc, Level, [Token | Tokens]) ->
	parse_record_field_assign([Token | Acc], Level, Tokens).

fill_remaining_field_assigns(Assigns, [], _Expr) ->
	Assigns;
fill_remaining_field_assigns(Assigns, [Field | Fields], Expr) ->
	case maps:find(Field, Assigns) of
		error -> fill_remaining_field_assigns(Assigns#{Field => Expr}, Fields, Expr);
		_     -> fill_remaining_field_assigns(Assigns, Fields, Expr)
	end.

make_tuple_from_record(RecordName, RevFieldList, Assigns, Line, IsPattern) ->
	make_tuple_from_record_impl([{atom, Line, RecordName}, {'{', Line}], lists:reverse(RevFieldList), Assigns, Line, IsPattern).

make_tuple_from_record_impl(Replacement, [Field | Fields], Assigns, Line, IsPattern) ->
	case maps:find(Field, Assigns) of
		{ok, {_FieldId, Initial}} ->
			case Initial of
				undefined ->
					case IsPattern of
					true  -> ActualValue = [{var, Line, '_'}];
						false -> ActualValue = [{atom, Line, undefined}]
					end;
				_ ->
					ActualValue = Initial
			end;
		{ok, Initial} when is_list(Initial) ->
			ActualValue = Initial;
		error ->
			case IsPattern of
				true  -> ActualValue = [{var, Line, '_'}];
				false -> ActualValue = [{atom, Line, undefined}]
			end
	end,
	make_tuple_from_record_impl(ActualValue ++ [{',', Line}] ++ Replacement, Fields, Assigns, Line, IsPattern);
make_tuple_from_record_impl(Replacement, [], _Assigns, Line, _IsPattern) ->
	[{'}', Line} | Replacement].

make_setelement_expr(FieldId, Expr, ValueExpr, Line) ->
	[
		{')', Line},
		{')', Line}
	]
	++ ValueExpr ++
	[
		{'(', Line},
		{',', Line},
		{')', Line}
	]
	++ Expr ++
	[
		{'(', Line},
		{',', Line},
		{integer, Line, FieldId},
		{'(', Line},
		{atom, Line, setelement},
		{':', Line},
		{atom, Line, erlang}
	].

make_getelement_expr(FieldId, Expr, Line) ->
	[
		{')', Line},
		{')', Line}
	]
	++ Expr ++
	[
		{'(', Line},
		{',', Line},
		{integer, Line, FieldId},
		{'(', Line},
		{atom, Line, element},
		{':', Line},
		{atom, Line, erlang}
	].

lk_initial() ->
	[head].

lk_pattern_position_hint([Head | _]) ->
	Head.

lk_call(List) ->
	case List of
		[{fun0} | _] -> List;
		[head   | _] -> List;
		_            -> [call | List]
	end.

lk_token(Tl, 'if') -> [expr | Tl];
lk_token(Tl, 'case') -> [expr | Tl];
lk_token(Tl, 'receive') -> [pattern | Tl];
lk_token([_|Tl], 'of') -> [pattern | Tl];
lk_token([H|Tl], 'when') -> [{when_, H} | Tl];
lk_token([{when_, H}|Tl], '->') -> [body, H | Tl];
lk_token(Tl, '->') -> [body | Tl];
lk_token([_ | Tl], ';') -> Tl;
lk_token([_, _ | Tl], 'end') -> Tl;
lk_token(Tl, 'fun') -> [{fun0} | Tl];
lk_token([{fun0} | Tl], ':') -> Tl;
lk_token([{fun0} | Tl], '/') -> Tl;
lk_token([{fun0} | Tl], '(') -> [head | Tl];
lk_token(LocKind, _) -> LocKind.

lk_update_hint(head, _) ->
	true;
lk_update_hint(pattern, _) ->
	true;
lk_update_hint(expr, _) ->
	false;
lk_update_hint(call, _) ->
	false;
lk_update_hint(X, _) when is_tuple(X) ->
	false;
lk_update_hint(body, Tokens) ->
	find_next_mapped_token(Tokens,
		#{
			'=' => true,
			',' => false,
			';' => false,
			dot => false
		},
		false);
lk_update_hint(Hint, []) ->
	case Hint of
		pattern -> true;
		_       -> false
	end.

find_next_mapped_token([{Token, _} | Tail], Map, Default) ->
	case maps:find(Token, Map) of
		{ok, Value} -> Value;
		error       -> find_next_mapped_token(Tail, Map, Default)
	end;
find_next_mapped_token([_Head | Tail], Map, Default) ->
	find_next_mapped_token(Tail, Map, Default);
find_next_mapped_token([], _Map, Default) ->
	Default.

new_level(Level, Tok) ->
	case Tok of
		'(' -> Level + 1;
		'[' -> Level + 1;
		'{' -> Level + 1;
		')' -> Level - 1;
		']' -> Level - 1;
		'}' -> Level - 1;
		_   -> Level
	end.

pack1(ListOfLists) ->
	pack1([], ListOfLists).

pack1(Acc, [Head | Tail]) ->
	pack1(Acc++Head, Tail);
pack1(Acc, []) ->
	Acc.

%list_contains([Term|_], Term) ->
%	true;
%list_contains([_|Tail], Term) ->
%	list_contains(Tail, Term);
%list_contains([], _Term) ->
%	false.

list_find(Fun, [Head|Tail]) ->
	case Fun(Head) of
		true  -> {ok, Head};
		false -> list_find(Fun, Tail)
	end;
list_find(_Fun, []) ->
	error.

parse_include(Filename, Forms, State) ->
	parse_include_impl(Filename, Forms, maps:get(include, State, ["."])).

parse_include_impl(Filename, Forms, [Dir|Dirs]) ->
	Filename2 = filename:join(Dir, Filename),
	%io:format("INCLUDE ~p~n", [Filename2]),
	try {ok, [], scan_forms(Filename2) ++ Forms}
	catch
		_:_ -> parse_include_impl(Filename, Forms, Dirs)
	end;
parse_include_impl(_Filename, _Forms, []) ->
	{error, no_such_include}.

parse_include_lib(Filename, Forms, State) ->
	Tokenized = string:tokens(Filename, "/\\"),
	LibDir = maps:get(lib_dir, State),
	{ok, ModuleList} = file:list_dir(LibDir),
	AbstractModule = hd(Tokenized),
	Prefix = AbstractModule ++ "-",
	case list_find(fun(S) -> 1 =:= string:str(S, Prefix) end, ModuleList) of
		{ok, ConcreteModule} -> parse_include_impl(filename:join([ConcreteModule | tl(Tokenized)]), Forms, [LibDir]);
		error                -> {error, no_such_module, AbstractModule}
	end.
