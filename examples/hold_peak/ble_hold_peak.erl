%%
%% Simple hold peak demo
%% 
-module(ble_hold_peak).

-export([start/0, start/1]).
-export([main/1]).
-export([run/1]).


-include("../include/uuid.hrl").

-define(ServiceUUID,?UUID(16#0000ffb0,16#0000,16#1000,16#8000,16#00805f9b34fb)).
-define(CharUUID,?UUID(16#0000ffb2,16#0000,16#1000,16#8000,16#00805f9b34fb)).

-define(DEFAULT_INTERFACE, "hci1").

start() ->
    run(#{ interface => ?DEFAULT_INTERFACE }).
start([Interface]) ->
    run(#{ interface => atom_to_list(Interface) });
start([Interface,Channel]) ->
    run(#{ interface => atom_to_list(Interface), hci_channel=>Channel }).

main(Args) ->
    Options = parse_args(Args, #{ interface => ?DEFAULT_INTERFACE }),
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
    

run(Options) ->
    {ok, Central} = ble:begin_central(Options),
    io:format("DEBUG: Calling setup~n"),
    SetupResult = setup(Central),
    io:format("DEBUG: setup returned: ~p~n", [SetupResult]),
    io:format("DEBUG: Calling ble:stop~n"),
    ble:stop(Central).

setup(Central) ->
    [Device|_] = find_device(Central),
    io:format("Device found : ~p\n", [Device]),
    init(Central, Device).

init(Central, Device) ->
    case ble:connect(Central, Device) of
	{ok, ConnRef} ->
            timer:sleep(200),
	    {ok, Services} = ble:discover(Central, Device, ConnRef),
	    io:format("Services found : ~p\n", [Services]),
	    loop(Central, Device, ConnRef, Services, ?ServiceUUID, ?CharUUID);
	Error ->
	    Error
    end.
	    
loop(Central, Device, ConnRef, _Services, _ServiceUUID, CharUUID) ->
    %% Subscribe to notifications instead of polling
    Callback = fun(_UUID, Value, _Origin) ->
                       case tmeter:decode(Value) of
                           {ok, {Val, Flags}} ->
                               io:format("Value = ~p ~w\n", [Val, Flags]);
                           Error ->
                               io:format("Decode error: ~p\n", [Error])
                       end
               end,
    case ble:subscribe(Central, CharUUID, Callback) of
        ok ->
            io:format("Subscribed to notifications~n"),
            Result = wait_loop(Central, Device, ConnRef, CharUUID),
            io:format("DEBUG: wait_loop returned: ~p~n", [Result]),
            Result;
        {error, Reason} ->
            io:format("Subscribe failed: ~p~n", [Reason]),
            {error, Reason}
    end.

wait_loop(Central, Device, ConnRef, CharUUID) ->
    %% Just wait - notifications will be handled by callback
    io:format("DEBUG: wait_loop entering receive~n"),
    receive
        {disconnected, Reason} ->
            io:format("DEBUG: Got {disconnected, ~p}~n", [Reason]),
            reconnect(Central, Device, ConnRef, CharUUID);
        Other ->
            io:format("DEBUG: wait_loop got unexpected message: ~p~n", [Other]),
            wait_loop(Central, Device, ConnRef, CharUUID)
    after 60000 ->
            io:format("DEBUG: wait_loop timeout, looping~n"),
            wait_loop(Central, Device, ConnRef, CharUUID)
    end.

reconnect(Central, Device, _ConnRef, CharUUID) ->
    case ble:connect(Central, Device) of
        {ok, ConnRef1} ->
            timer:sleep(200),
            %% Re-discover to populate Objects map
            case ble:discover_services(Central, ConnRef1) of
                {ok, Services} ->
                    lists:foreach(
                      fun(Service) ->
                              ble:discover_characteristics(Central, ConnRef1, Service)
                      end, Services),
                    loop(Central, Device, ConnRef1, Services, ?ServiceUUID, CharUUID);
                {error, Reason} ->
                    io:format("Discovery failed: ~p~n", [Reason]),
                    timer:sleep(2000),
                    reconnect(Central, Device, undefined, CharUUID)
            end;
        _Error ->
            timer:sleep(2000),
            reconnect(Central, Device, undefined, CharUUID)
    end.


find_device(Central) ->
    Devices = ble:scan(Central, 5000, 
		       %% find devices matching the service
		       fun({uuids, UUIDs}) ->
			       lists:member(?ServiceUUID, UUIDs);
			  (_) ->
			       false
		       end),
    case Devices of
	[] -> find_device(Central);
	_ -> Devices
    end.
