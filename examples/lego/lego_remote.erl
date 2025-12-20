%%
%% Simple lego remote demo
%% 
-module(lego_remote).

-export([start/0, start/1]).
-export([main/1]).
-export([run/1]).

-include_lib("bt/include/uuid.hrl").
-include_lib("bt/include/bt_log.hrl").

-include("lego_messages.hrl").

-define(ServiceUUID,?UUID(16#00001623,16#1212,16#EFDE,16#1623,16#785FEABCD123)).
-define(CharUUID,?UUID(16#00001624,16#1212,16#EFDE,16#1623,16#785FEABCD123)).

-define(DEFAULT_INTERFACE, "hci1").

-define(CCCD_NOTIFY,   16#0001).
-define(CCCD_INDICATE, 16#0002).

start() ->
    run(#{ interface => ?DEFAULT_INTERFACE }).
start([Interface]) ->
    run(#{ interface => atom_to_list(Interface) });
start([Interface, Channel]) ->
    run(#{ interface => atom_to_list(Interface), hci_channel => Channel }).

main(Args) ->
    Options0 = #{ interface => ?DEFAULT_INTERFACE },
    Options = parse_args(Args, Options0),
    run(Options).

parse_args(["-i", Interface|Args], Opts) ->
    parse_args(Args, Opts#{ interface => Interface });
parse_args(["-i"++Interface|Args], Opts) ->    
    parse_args(Args, Opts#{ interface => Interface });
parse_args(["-c", Channel|Args], Opts) ->
    parse_args(Args, Opts#{ hci_channel => list_to_atom(Channel) });
parse_args(["-c"++Channel|Args], Opts) ->    
    parse_args(Args, Opts#{ hci_channel => list_to_atom(Channel) });
parse_args(_, Opts) -> 
    Opts.

run(Options0) ->
    Options = Options0#{adv_decoder => lego_ble},
    {ok, Central} = ble:begin_central(Options),
    io:format("DEBUG: Calling setup~n"),
    SetupResult = init0(Central),
    io:format("DEBUG: setup returned: ~p~n", [SetupResult]),
    io:format("DEBUG: Calling ble:stop~n"),
    ble:stop(Central).

init0(Central) ->
    [Device|_] = find_device(Central),
    io:format("Device found : ~p\n", [Device]),
    init1(Central, Device).

init1(Central, Device) ->
    case discover_device(Central, Device) of
	{ok, ConnRef, Service, Char} ->
	    setup(Central, Device, ConnRef, Service, Char);
	Error ->
	    Error
    end.

discover_device(Central, Device) ->
    case ble:connect(Central, Device) of
	{ok, ConnRef} ->
            timer:sleep(200),
	    {ok, Services} = ble:discover_services(Central, ConnRef),
	    Services1 = 
		[ 
		  case ble:discover_characteristics(Central,ConnRef,Service) of 
		      {ok,Chars} ->
			  Service#{characteristics=>Chars};
		      {error,_} ->
			  Service
		  end || Service <- Services],
	    io:format("Services found : ~p\n", [Services1]),
	    case ble:find_characteristic(?CharUUID, Services1) of
		error ->
		    %%
		    ?error("characteristc handle not found"),
		    {error, no_char};
		Char ->
		    setup(Central, Device, ConnRef, Services1, Char)
	    end
    end.

-define(MAX_SPEED, 40).
-define(MIN_SPEED, 5).
-define(STEP_SPEED, 3).
    
setup(Central, Device, ConnRef, _Services, Char) ->
    %% Subscribe to notifications instead of polling
    %% Callback is called from Central process!
    %% SELF = self(),
    Callback =
	fun(_UUID, Value, _Origin) ->
		io:format("Notification: ~p\n", [Value])
	end,

    #{ uuid := CharUUID, value_handle := ValueHandle} = Char,
    case ble:subscribe(Central, CharUUID, Callback) of
        ok ->
            io:format("Subscribed to notifications~n"),
	    Value = <<?CCCD_NOTIFY:16/little>>,
	    ble:write_handle(Central, ConnRef, ValueHandle+1, Value),
	    Result = wait_loop(Central, Device, ConnRef, Char, 
			       ValueHandle, ?MIN_SPEED, ?STEP_SPEED),
	    io:format("DEBUG: wait_loop returned: ~p~n", [Result]),
	    Result;
        {error, Reason} ->
            io:format("Subscribe failed: ~p~n", [Reason]),
            {error, Reason}
    end.

wait_loop(Central, Device, ConnRef, Char, ValueHandle, Power, Step) ->
    %% Just wait - notifications will be handled by callback
    io:format("DEBUG: wait_loop entering receive~n"),
    receive
	setup ->
	    #{ value_handle := ValueHandle} = Char,
	    FamilyCmd = lego_messages:encode_connection_complete(),
	    ble:write_handle(Central, ConnRef, ValueHandle, FamilyCmd),
	    %% LeftCmd = LeftCmd = lego_messages:encode_enable_port_notifications(0),
	    %% ble:write_handle(Central, ConnRef, ValueHandle, LeftCmd),
	    %% RightCmd = lego_messages:encode_enable_port_notifications(1),
	    %% ble:write_handle(Central, ConnRef, ValueHandle, RightCmd),
	    wait_loop(Central, Device, ConnRef, Char, ValueHandle, Power, Step);

        {disconnected, Reason} ->
            io:format("DEBUG: Got {disconnected, ~p}~n", [Reason]),
	    #{ uuid := CharUUID } = Char,
            reconnect(Central, Device, ConnRef, CharUUID);

        Other ->
            io:format("DEBUG: wait_loop got unexpected message: ~p~n", [Other]),
            wait_loop(Central, Device, ConnRef, Char, ValueHandle, Power, Step)
    after 1000 ->
	    PortID = 0,
	    StartupInfo = 0,  % Buffer if necessary
	    SubCommand = 16#51,  % WriteDirectModeData
	    Mode = 0,  % Power mode
	    Payload = <<PortID:8, StartupInfo:8, SubCommand:8, Mode:8, Power:8>>,
	    %% Port Output Command
	    Msg = #{ type => 16#81, hub_id => 0, payload => Payload },
	    Cmd = lego_messages:encode_message(Msg),
	    ble:write_handle(Central, ConnRef, ValueHandle, Cmd),
	    if Power >= ?MAX_SPEED, Step > 0 ->
		    wait_loop(Central, Device, ConnRef, Char, 
			      ValueHandle, Power, -Step);
	       Power =< ?MIN_SPEED, Step < 0 ->
		    wait_loop(Central, Device, ConnRef, Char, 
			      ValueHandle, Power, -Step);
	       true ->
		    wait_loop(Central, Device, ConnRef, Char, 
			      ValueHandle, Power+Step, Step)
	    end
    end.

reconnect(Central, Device, _ConnRef, CharUUID) ->
    case discover_device(Central, Device) of
	{ok, ConnRef, Services, Char} ->
	    setup(Central, Device, ConnRef, Services, Char);
	{error, Reason} ->
	    io:format("Discovery failed: ~p~n", [Reason]),
	    timer:sleep(2000),
	    reconnect(Central, Device, undefined, CharUUID)
    end.

find_device(Central) ->
    Devices = ble:scan(Central, 5000, 
		       %% find devices matching the service
		       fun match_hub/1),
    case Devices of
	[] -> find_device(Central);
	_ -> Devices
    end.

match_hub(Adv) ->
    io:format("match device ~p\n", [Adv]),
    case match_device_(Adv, 0) of
	true ->
	    io:format("YES\n"),
	    true;
	false ->
	    io:format("NO\n"),
	    false
    end.

match_device_([{uuids, UUIDs}|Adv], Match) ->
    case lists:member(?ServiceUUID, UUIDs) of
	false -> 
	    false;
	true -> 
	    io:format("MATCHED UUIDS\n"),
	    match_device_(Adv, Match bor 2#01)
    end;
match_device_([{manufacturer, Manuf}|Adv], Match) ->
    case Manuf of
	#{ manufacturer_id := ?LEGO_MANUFACTURER_ID,
	   %% button_state := pressed,
	   system_type := system, %% 2#010,
	   device_number := 2#00001,
	   status := #{ can_be_peripheral := true,
			request_window := true }} ->
	    match_device_(Adv, Match bor 2#10);
	_ ->
	    false
    end;
match_device_([_|Adv], Match) ->
    match_device_(Adv, Match);
match_device_([], Match) -> %% must match both uuid and matching state
    Match =:= 2#11.
