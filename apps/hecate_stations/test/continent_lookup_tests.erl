%% @doc Static reference-table lookups. No I/O, nothing to fixture.
-module(continent_lookup_tests).

-include_lib("eunit/include/eunit.hrl").

known_country_resolves_its_continent_test_() ->
    [?_assertEqual(<<"Europe">>, continent_lookup:continent(<<"BE">>)),
     ?_assertEqual(<<"North America">>, continent_lookup:continent(<<"US">>)),
     ?_assertEqual(<<"South America">>, continent_lookup:continent(<<"BR">>)),
     ?_assertEqual(<<"Asia">>, continent_lookup:continent(<<"JP">>)),
     ?_assertEqual(<<"Africa">>, continent_lookup:continent(<<"ZA">>)),
     ?_assertEqual(<<"Oceania">>, continent_lookup:continent(<<"AU">>))].

unknown_country_code_test() ->
    ?assertEqual(<<"unknown">>, continent_lookup:continent(<<"XX">>)).

empty_binary_is_unknown_not_a_crash_test() ->
    ?assertEqual(<<"unknown">>, continent_lookup:continent(<<>>)).
