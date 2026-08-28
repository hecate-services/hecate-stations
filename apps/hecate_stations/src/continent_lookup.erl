%% @doc ISO 3166-1 alpha-2 country code -> continent. Static reference
%% data, not sourced from the mesh -- unlike a station list, country
%% codes don't get renamed out from under you. Covers the countries
%% currently in play across the macula-demo fleet plus enough of the
%% rest of the world to not need touching again for a long while;
%% extend the table as new stations land somewhere new.
-module(continent_lookup).

-export([continent/1]).

-spec continent(binary()) -> binary().
continent(Country) ->
    maps:get(Country, table(), <<"unknown">>).

table() ->
    #{
        %% Europe
        <<"DE">> => <<"Europe">>, <<"FR">> => <<"Europe">>, <<"IT">> => <<"Europe">>,
        <<"SE">> => <<"Europe">>, <<"FI">> => <<"Europe">>, <<"BE">> => <<"Europe">>,
        <<"NL">> => <<"Europe">>, <<"ES">> => <<"Europe">>, <<"PT">> => <<"Europe">>,
        <<"GB">> => <<"Europe">>, <<"IE">> => <<"Europe">>, <<"PL">> => <<"Europe">>,
        <<"CH">> => <<"Europe">>, <<"AT">> => <<"Europe">>, <<"DK">> => <<"Europe">>,
        <<"NO">> => <<"Europe">>, <<"CZ">> => <<"Europe">>, <<"GR">> => <<"Europe">>,
        <<"RO">> => <<"Europe">>, <<"HU">> => <<"Europe">>,
        %% North America
        <<"US">> => <<"North America">>, <<"CA">> => <<"North America">>,
        <<"MX">> => <<"North America">>,
        %% South America
        <<"BR">> => <<"South America">>, <<"AR">> => <<"South America">>,
        <<"CL">> => <<"South America">>, <<"CO">> => <<"South America">>,
        %% Asia
        <<"JP">> => <<"Asia">>, <<"CN">> => <<"Asia">>, <<"IN">> => <<"Asia">>,
        <<"SG">> => <<"Asia">>, <<"KR">> => <<"Asia">>, <<"ID">> => <<"Asia">>,
        %% Africa
        <<"ZA">> => <<"Africa">>, <<"NG">> => <<"Africa">>, <<"EG">> => <<"Africa">>,
        <<"KE">> => <<"Africa">>,
        %% Oceania
        <<"AU">> => <<"Oceania">>, <<"NZ">> => <<"Oceania">>
    }.
