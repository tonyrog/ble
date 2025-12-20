%%% @doc
%%% BLE Lego Controller simulator
%%%
%%% Usage:
%%%   1> c(ble_lego_controller).
%%%   2> ble_lego_controller:start().
%%%
%%% @end
-module(lego_controller).
-export([start/0, start/1, stop/1]).
-export([update_lego_controller/3]).
-export([encode_button_state/2]).

-include_lib("bt/include/bt.hrl").
-include("lego_messages.hrl").

-define(ServiceUUID,?UUID(16#00001623,16#1212,16#EFDE,16#1623,16#785FEABCD123)).
-define(CharUUID,?UUID(16#00001624,16#1212,16#EFDE,16#1623,16#785FEABCD123)).

start() ->
    start(#{ device_name => "Lego-HandSet", 
	     adv_decoder => lego_ble,
	     adv_encoder => lego_ble 
	   }).

start(Options = #{ device_name := DeviceName }) ->
    %% Initialize BLE as Peripheral (like Arduino BLE.begin())
    {ok, BLE} = ble:begin_peripheral(Options),
    ble:accept_all_ltk(BLE),

    %% Add Lego Service UUID
    ok = ble:add_service(BLE, ?ServiceUUID),

    %% Add Lego Service characteristic
    %% Properties: notify (can send updates to connected devices)

    ok = ble:add_characteristic(BLE, ?CharUUID,
                                [write_without_response,write,notify],
                                <<>>),

    %% Start advertising (like BLE.advertise())
    ok = ble:set_advertising_data(BLE, state(1)),

    ok = ble:advertise(BLE),

    io:format("~n"),
    io:format("==============================================~n"),
    io:format(" Lego Controller simulator Started!\n"),
    io:format(" Device: ~s\n", [DeviceName]),
    io:format(" Service: ~s\n", [bt_util:uuid_to_string(?ServiceUUID)]),
    io:format("==============================================~n"),
    io:format("\n"),
    io:format("Advertising...\n\n"),

    %% Start simulating heart rate
    spawn_link(fun() -> simulate_lego_controller(BLE) end),

    {ok, BLE}.

stop(BLE) ->
    ble:stop_advertising(BLE),
    ble:stop(BLE),
    ok.

state(ButtonState) ->
    #{
       button_state => ButtonState, %% green button, pressed
       system_type => 2#010,
       device_number => 2#00010,
       capabilities => 
	   #{ central_role => false,
	      peripheral_role => true,
	      lpf2_devices => false,
	      remote_controler => true
	    },
       last_network_id => 0,
       status =>
	   #{
	     can_be_peripheral => true,
	     can_be_central => false,
	     request_window => true,
	     request_connect => true
	    },
       option => 0
     }.

encode_button_state(PortID, Button) ->
    Payload = lego_messages:encode_port_value_data(PortID, Button),
    Mesg = #{ type => ?MSG_PORT_VALUE_SINGLE,
	      hub_id => 0,
	      payload => Payload },
    lego_messages:encode_message(Mesg).

%% update controller value
update_lego_controller(BLE, Button0, Button1) ->
    Value0 = encode_button_state(0, Button0),
    Value1 = encode_button_state(1, Button1),

    ble:write_value(BLE, ?CharUUID, Value0),
    timer:sleep(100),
    ble:write_value(BLE, ?CharUUID, Value1),
    timer:sleep(100),
    ok.

%% Simulate realistic heart rate variations
simulate_lego_controller(BLE) ->
    simulate_loop(BLE, 0).

simulate_loop(BLE, Counter) ->
    Button0 = case Counter band 8#07 of
		  0 -> released;
		  1 -> plus;
		  2 -> released;
		  3 -> minus;
		  4 -> released;
		  5 -> red;
		  6 -> released;
		  7 -> red
	      end,
    Button1 = case (Counter band 8#70) bsr 3 of
		  0 -> released;
		  1 -> plus;
		  2 -> released;
		  3 -> minus;
		  4 -> released;
		  5 -> red;
		  6 -> released;
		  7 -> red
	      end,
    timer:sleep(1000),

    update_lego_controller(BLE, Button0, Button1),

    io:format("Button0: ~p~n", [Button0]),
    io:format("Button1: ~p~n", [Button1]),
    
    simulate_loop(BLE, Counter + 1).

