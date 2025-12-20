%%% @author Tony Rogvall <tony@rogvall.se>
%%% @copyright (C) 2025, Tony Rogvall
%%% @doc
%%%    Some test functions
%%% @end
%%% Created : 14 Dec 2025 by Tony Rogvall <tony@rogvall.se>

-module(ble_test).

-export([test_connect/1, test_connect/2]).
-export([test_scan/0, test_scan/1]).
-export([list_devices/0, list_devices/1]).

-include_lib("bt/include/bt.hrl").

list_devices() ->
    list_devices(#{}).

list_devices(Options) ->
    {ok, Central} = ble:begin_central(Options),
    Devices = ble:scan(Central, 5000),
    ble:stop(Central),
    ble:display_devices(Devices).
    
test_scan() -> test_scan(#{}).
test_scan(Options) ->
    {ok, Central} = ble:begin_central(Options),
    ble:scan(Central, 5000).

%% connect lego remote control
test_connect(What) ->
    test_connect(What, #{}).
test_connect(What, Options) ->
    {ok, Central} = ble:begin_central(Options),
    DefaultType = maps:get(addr_type, Options, public),
    {AddrType,Addr}
	= case What of
	      lego -> {DefaultType, {192,99,128,37,255,144}};
	      oral_b -> {DefaultType, {48,226,131,155,152,153}};
	      Mac when ?is_bt_mac(Mac) -> {DefaultType, Mac};
	      Dev when is_map(Dev) -> 
		  {maps:get(addr_type, Dev, DefaultType),
		   maps:get(addr, Dev)};
	      String when is_list(String) ->
		  {DefaultType, bt_util:getaddr(String)}
	  end,
    Device = #{ addr => Addr, addr_type => AddrType },
    Result = ble:discover(Central, Device),
    ble:stop(Central),
    Result.



