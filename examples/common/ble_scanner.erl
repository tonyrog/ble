%%% @doc
%%% BLE Scanner - Central Example
%%%
%%% Scan for nearby BLE devices (like Arduino BLE.scan())
%%% Simple and easy!
%%%
%%% Usage:
%%%   1> c(ble_scanner).
%%%   2> ble_scanner:scan().
%%%   3> ble_scanner:scan(10000).  % Scan for 10 seconds
%%%
%%% @end
-module(ble_scanner).
-export([start/0, start/1]).
-export([run/2]).

start() ->
    start(['10000']).

start([TimeoutAtom]) ->
    Timeout = list_to_integer(atom_to_list(TimeoutAtom)),
    run(Timeout, #{}).

run(Timeout, Options) ->
    io:format("~n"),
    io:format("==============================================~n"),
    io:format(" BLE Scanner~n"),
    io:format(" Scanning for ~w ms...~n", [Timeout]),
    io:format("==============================================~n"),
    io:format("~n"),

    %% Initialize BLE as Central (like Arduino BLE.begin())
    {ok, BLE} = ble:begin_central(Options),

    %% Scan for devices
    Devices = ble:scan(BLE, Timeout),

    io:format("~n"),
    io:format("Found ~w devices:~n", [length(Devices)]),
    io:format("~n"),

    %% Print each device
    lists:foreach(fun(Device) ->
        ble:print_device(Device)
    end, Devices),

    io:format("~n"),
    io:format("Scan complete!~n"),
    io:format("~n"),

    %% Cleanup
    ble:stop(BLE),

    {ok, Devices}.

