%%% @doc
%%% BLE Hold Peak simulator
%%%
%%% Usage:
%%%   1> c(ble_hole_peak_meter).
%%%   2> ble_hole_peak_meterstart().
%%%
%%% @end
-module(ble_hold_peak_meter).
-export([start/0, start/1, stop/1]).
-export([update_hold_peak/2]).

-include_lib("bt/include/bt.hrl").

-define(ServiceUUID,?UUID(16#0000ffb0,16#0000,16#1000,16#8000,16#00805f9b34fb)).
-define(CharUUID,?UUID(16#0000ffb2,16#0000,16#1000,16#8000,16#00805f9b34fb)).

start() ->
    start(#{ device_name => "Erlang-HoldPeak" }).

start(Options = #{ device_name := DeviceName }) ->
    %% Initialize BLE as Peripheral (like Arduino BLE.begin())
    {ok, BLE} = ble:begin_peripheral(Options),
    ble:accept_all_ltk(BLE),

    %% Add Hold Peak Service (like BLE.addService())
    ok = ble:add_service(BLE, ?ServiceUUID),

    %% Add Hold Peak characteristic
    %% Properties: notify (can send updates to connected devices)
    BaseVoltage = 12.3,
    Value = tmeter:encode(BaseVoltage, #{ unit=>volt }),
    ok = ble:add_characteristic(BLE, ?CharUUID,
                                [read, notify],
                                Value),  % Initial value: 12.3V

    %% Start advertising (like BLE.advertise())
    ok = ble:advertise(BLE),

    io:format("~n"),
    io:format("==============================================~n"),
    io:format(" HoldPeak Generator Started!\n"),
    io:format(" Device: ~s\n", [DeviceName]),
    io:format(" Service: ~s\n", [bt_util:uuid_to_string(?ServiceUUID)]),
    io:format("==============================================~n"),
    io:format("\n"),
    io:format("Advertising...\n\n"),

    %% Start simulating heart rate
    spawn_link(fun() -> simulate_hold_peak(BLE, BaseVoltage) end),

    {ok, BLE}.

stop(BLE) ->
    ble:stop_advertising(BLE),
    ble:stop(BLE),
    ok.


%% Update heart rate value
update_hold_peak(BLE, Voltage) when is_number(Voltage) ->
    Value = tmeter:encode(Voltage, #{ unit=>volt }),
    ble:write(BLE, ?CharUUID, Value),
    io:format("Hold Peak updated: ~fV\n", [Voltage]).

%% Simulate realistic heart rate variations
simulate_hold_peak(BLE, BaseVoltage) ->
    simulate_loop(BLE, BaseVoltage, 0).

simulate_loop(BLE, BaseVoltage, Counter) ->
    %% Add some variation (sine wave + random)
    Variation = 2 * math:sin(Counter / 10.0),
    Voltage = clip(BaseVoltage + Variation, 9.0, 15.0),

    %% Update every 1 second
    timer:sleep(1000),

    %% Write new value
    Value = tmeter:encode(Voltage, #{ unit=>volt }),
    ble:write_value(BLE, ?CharUUID, Value),

    %% Print every 5 seconds
    case Counter rem 5 of
        0 -> 
	    io:format("Voltage: ~f~n", [Voltage]);
        _ ->
	    ok
    end,
    simulate_loop(BLE, BaseVoltage, Counter + 1).

clip(Value, Min, Max) ->
    min(max(Value, Min), Max).

    
