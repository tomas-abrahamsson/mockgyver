%%%-------------------------------------------------------------------
%%% @author Klas Johansson klas.johansson@gmail.com
%%% @copyright (C) 2010, Klas Johansson
%%% @doc
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(mockgyver_xform).

%% This might be confusing, but this module (which is a parse
%% transform) is actually itself parse transformed by a 3pp library
%% (http://github.com/esl/parse_trans).  This transform makes it
%% easier for this module to generate code within the modules it
%% transforms.  Simple, eh? :-)
-compile({parse_transform, parse_trans_codegen}).

%% API
-export([parse_transform/2]).

%% Records
-record(m_init, {exec_fun}).
-record(m_when, {m, f, a, action}).
-record(m_was_called, {m, f, a, g, crit}).

-record(env, {mock_mfas, trace_mfas}).

%%%===================================================================
%%% API
%%%===================================================================

parse_transform(Forms, Opts) ->
    parse_trans:top(fun parse_transform_2/2, Forms, Opts).

parse_transform_2(Forms0, Ctxt) ->
    Env = #env{mock_mfas  = find_mfas_to_mock(Forms0, Ctxt),
               trace_mfas = find_mfas_to_trace(Forms0, Ctxt)},
    {Forms1, _} = rewrite_init_stmts(Forms0, Ctxt, Env),
    {Forms2, _} = rewrite_when_stmts(Forms1, Ctxt),
    {Forms, _}  = rewrite_was_called_stmts(Forms2, Ctxt),
    parse_trans:revert(Forms).

%%------------------------------------------------------------
%% init statements
%%------------------------------------------------------------
rewrite_init_stmts(Forms, Ctxt, Env) ->
    parse_trans:do_transform(fun rewrite_init_stmts_2/4, Env, Forms, Ctxt).

rewrite_init_stmts_2(Type, Form0, _Ctxt, Env) ->
    case is_mock_expr(Type, Form0) of
        {true, #m_init{exec_fun=ExecFun}} ->
            Befores = [],
            MockMfas = Env#env.mock_mfas,
            TraceMfas = Env#env.trace_mfas,
            [Form] = codegen:exprs(
                       fun() ->
                               mockgyver:exec({'$var',  MockMfas},
                                              {'$var',  TraceMfas},
                                              {'$form', ExecFun})
                       end),
            Afters = [],
            {Befores, Form, Afters, false, Env};
        _ ->
            {Form0, true, Env}
    end.

%%------------------------------------------------------------
%% when statements
%%------------------------------------------------------------
rewrite_when_stmts(Forms, Ctxt) ->
    parse_trans:do_transform(fun rewrite_when_stmts_2/4, x, Forms, Ctxt).

rewrite_when_stmts_2(Type, Form0, _Ctxt, Acc) ->
    case is_mock_expr(Type, Form0) of
        {true, #m_when{m=M, f=F, action=ActionFun}} ->
            Befores = [],
            [Form] = codegen:exprs(
                       fun() ->
                               mockgyver:set_action({{'$var', M}, {'$var', F},
                                                     {'$form', ActionFun}})
                       end),
            Afters = [],
            {Befores, Form, Afters, false, Acc};
        _ ->
            {Form0, true, Acc}
    end.

find_mfas_to_mock(Forms, Ctxt) ->
    lists:usort(
      parse_trans:do_inspect(fun find_mfas_to_mock_f/4, [], Forms, Ctxt)).

find_mfas_to_mock_f(Type, Form, _Ctxt, Acc) ->
    case is_mock_expr(Type, Form) of
        {true, #m_when{} = W} -> {false, [when_to_mfa(W) | Acc]};
        {true, _}             -> {true, Acc};
        false                 -> {true, Acc}
    end.

when_to_mfa(#m_when{m=M, f=F, a=A}) ->
    {M, F, A}.

%%------------------------------------------------------------
%% was called statements
%%------------------------------------------------------------
rewrite_was_called_stmts(Forms, Ctxt) ->
    parse_trans:do_transform(fun rewrite_was_called_stmts_2/4, x, Forms, Ctxt).

rewrite_was_called_stmts_2(Type, Form0, _Ctxt, Acc) ->
    case is_mock_expr(Type, Form0) of
        {true, #m_was_called{m=M, f=F, a=A, g=G, crit=C}} ->
            MS = args_to_match_spec(A, G),
            Befores = [],
            [Form] = codegen:exprs(
                       fun() ->
                               mockgyver:was_called(
                                 {{'$var',M},{'$var',F},{'$var',MS}},{'$var',C})
                       end),
            Afters = [],
            {Befores, Form, Afters, false, Acc};
        _ ->
            {Form0, true, Acc}
    end.

find_mfas_to_trace(Forms, Ctxt) ->
    lists:usort(
      parse_trans:do_inspect(fun find_mfas_to_trace_f/4, [], Forms, Ctxt)).

find_mfas_to_trace_f(Type, Form, _Ctxt, Acc) ->
    case is_mock_expr(Type, Form) of
        {true, #m_was_called{} = WC} -> {false, [was_called_to_tpat(WC) | Acc]};
        {true, _}                    -> {true, Acc};
        false                        -> {true, Acc}
    end.

was_called_to_tpat(#m_was_called{m=M, f=F, a=A}) ->
    {M, F, length(A)}. % a trace pattern we can pass to erlang:trace_pattern

%%------------------------------------------------------------
%% mock expression analysis
%%------------------------------------------------------------
is_mock_expr(tuple, Form) ->
    case erl_syntax:tuple_elements(Form) of
        [H | T] ->
            case erl_syntax:is_atom(H, '$mock') of
                true  -> {true, analyze_mock_form(T)};
                false -> false
            end;
        _Other ->
            false
    end;
is_mock_expr(_Type, _Form) ->
    false.

analyze_mock_form([Type, Expr]) ->
    case erl_syntax:atom_value(Type) of
        m_init       -> analyze_init_expr(Expr);
        m_when       -> analyze_when_expr(Expr);
        m_was_called -> analyze_was_called_expr(Expr)
    end.

analyze_init_expr(Expr) ->
    #m_init{exec_fun=Expr}.

analyze_when_expr(Expr) ->
    %% The sole purpose of the entire if expression is to let us write
    %%     ?WHEN(m:f(_) -> some_result).
    %% or
    %%     ?WHEN(m:f(1) -> some_result;).
    %%     ?WHEN(m:f(2) -> some_other_result).
    Clauses0 = erl_syntax:case_expr_clauses(Expr),
    {M, F, A} = ensure_all_clauses_implement_the_same_function(Clauses0),
    Clauses = lists:map(fun(Clause) ->
                                [Call | _] = erl_syntax:clause_patterns(Clause),
                                {_M, _F, Args} = analyze_application(Call),
                                Guard = erl_syntax:clause_guard(Clause),
                                Body  = erl_syntax:clause_body(Clause),
                                erl_syntax:clause(Args, Guard, Body)
                        end,
                        Clauses0),
    ActionFun = erl_syntax:fun_expr(Clauses),
    #m_when{m=M, f=F, a=A, action=ActionFun}.

ensure_all_clauses_implement_the_same_function(Clauses) ->
    lists:foldl(fun(Clause, undefined) ->
                        get_when_call_sig(Clause);
                   (Clause, {M, F, A}=MFA) ->
                        case get_when_call_sig(Clause) of
                            {M, F, A} ->
                                MFA;
                            OtherMFA ->
                                erlang:error({when_expr_function_mismatch,
                                              {expected, MFA},
                                              {got, OtherMFA}})
                        end
                end,
                undefined,
                Clauses).

get_when_call_sig(Clause) ->
    [Call | _] = erl_syntax:clause_patterns(Clause),
    {M, F, A} = analyze_application(Call),
    {M, F, length(A)}.

analyze_was_called_expr(Form) ->
    [Case, Criteria] = erl_syntax:tuple_elements(Form),
    [Clause | _] = erl_syntax:case_expr_clauses(Case),
    [Call | _] = erl_syntax:clause_patterns(Clause),
    G = erl_syntax:clause_guard(Clause),
    {M, F, A} = analyze_application(Call),
    #m_was_called{m=M, f=F, a=A, g=G, crit=erl_syntax:concrete(Criteria)}.

args_to_match_spec(Args, Guard) ->
    %% The idea here is that we'll use the match spec transform from
    %% the shell.  Example:
    %%
    %%     1> dbg:fun2ms(fun([1]) -> ok end)
    %%     [{[1,2],[],[ok]}]
    %%
    %% The shell does this by taking the parsed clauses from the fun:
    %%
    %%     [{clause,1,
    %%      [{cons,1,
    %%        {integer,1,1},
    %%        {cons,1,{integer,1,2},{nil,1}}}],
    %%      [],
    %%      [{atom,1,ok}]}]
    %%
    %% ... and passing it to:
    %%
    %%     ms_transform:transform_from_shell(dbg, Expr)
    Clause = erl_syntax:clause(_Pat=[erl_syntax:revert(erl_syntax:list(Args))],
                               Guard,
                               _Body=[erl_syntax:atom(dummy)]),
    Clauses = parse_trans:revert([Clause]),
    ms_transform:transform_from_shell(dbg, Clauses, []).

analyze_application(Form) ->
    MF = erl_syntax:application_operator(Form),
    M  = erl_syntax:concrete(erl_syntax:module_qualifier_argument(MF)),
    F  = erl_syntax:concrete(erl_syntax:module_qualifier_body(MF)),
    A  = erl_syntax:application_arguments(Form),
    {M, F, A}.
