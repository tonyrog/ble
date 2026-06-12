%%% @author Tony Rogvall <tony@rogvall.se>
%%% @copyright (C) 2025, Tony Rogvall
%%% @doc
%%%    BLE (Bluetooth Low Energy) High-Level API
%%%    Arduino-style simplicity with Erlang power!
%%%
%%%    Quick Start:
%%%      1. As Peripheral (Server):
%%%         {ok, Peripheral} = 
%%%           ble:begin_peripheral(#{ interface => "hci0", 
%%%                                   device_name => "MyDevice"}),
%%%         ble:add_service(Peripheral, "180D"),  % Heart Rate Service
%%%         ble:advertise(Peripheral).
%%%
%%%      2. As Central (Client):
%%%         {ok, Central} = ble:begin_central(#{ interface => "hci0" }),
%%%         Devices = ble:scan(Central, 5000),
%%%         {ok, Dev} = ble:connect(Central, DeviceAddr).
%%%
%%% @end
%%% Created : 18 Nov 2025 by Tony Rogvall <tony@rogvall.se>

-module(ble).

%% High-level API - Arduino style!
-export([
	 %% Setup
	 begin_peripheral/0, begin_peripheral/1,
	 begin_central/0, begin_central/1,
	 stop/1,

	 %% Peripheral (Server) mode
	 set_device_name/2,
	 add_service/2, add_service/3,
	 add_characteristic/4, add_characteristic/5,
	 advertise/1, advertise/2,
	 set_advertising_data/2,
	 stop_advertising/1,
	 
	 %% Central (Client) mode
	 scan/1, scan/2, scan/3,
	 connect/2, connect/3,
	 disconnect/2,
	 discover_services/2,
	 discover_characteristics/3,

	 %% GATT operations (works for both Central and Peripheral)
	 read/3,       %% read peripheral value (central)
	 write/4,      %% write peripheral value (central)

	 read_handle/3,  %% read peripheral value (central)
	 write_handle/4, %% write peripheral value (central)
	 read_value/3,   %% read cached value (central)

	 read_value/2,  %% read cached value (peripheral)
	 write_value/3, %% write cached & indicate value (peripheral)

	 subscribe/3,
	 unsubscribe/2,
	 
	 %% Utility
	 uuid/1,
	 print_device/1,
	 discover/2,
	 discover/3,
	 get_type_and_addr/1,
	 find_characteristic/2,

	 %% Advanced - HCI management
	 reset_hci/0, reset_hci/1,

	 %% Security - LTK management
	 set_ltk/3,
	 get_ltk/2,
	 clear_ltk/2,

	 %% Security - Testing
	 accept_all_ltk/1,
	 reject_all_ltk/1,

	 %% Subscriber callback
	 call_subscribers/4
	]).

%% internal
-export([central_loop/1]).
-export([peripheral_loop/1]).
-export([display_devices/1]).
-export([display_device/1]).
-export([display_services/3]).

-include_lib("bt/include/bt.hrl").
-include_lib("bt/include/hci.hrl").
-include_lib("bt/include/hci_api.hrl").

-include("../include/ble_log.hrl").

-include("ble_state.hrl").
-include("gatt_client.hrl").

-type ble_handle() :: pid().
-type ble_connection() :: reference().
-type char_properties() :: [read | write | notify | indicate].
-type uuid_string() :: string() | atom() | uuid(). %% uid input
-type device() :: #{ addr => bt_addr(),
		     addr_type => public | random | 1 | 0 }.
-type timeout_ms() :: integer().

-define(DEFAULT_CONNECT_TIMEOUT, 5000).
-define(HCI_TIMEOUT, 2000).
-define(HCI_NOEVENT, -1).

-define(DEFAULT_CHANNEL, user).

-type ble_options() :: 
	#{
	  device_name => string(),  %% name
	  hci_channel => raw | user, %% (default is ?DEFAULT_CHANNEL)
	  adv_decoder => atom(),  %% advertisment manufacturer decoder module
	  adv_encoder => atom(),  %% advertisment manufacturer encoder module
	  disable_pairing => boolean()
	 }.

-type adv_options() :: 
	#{ 
	   interval => integer(),     %% defalt 500ms
	   type => connectable | scannable | not_connectable | directed,
	   own_addr_type => public | random
	 }.

%%
%% Discover service via address or device from scan
%% may check cache or cache the data
%%
-spec discover(Central::ble_handle(), Device::bt_mac()|device()) ->
	  {ok, [service()]} | {error, Reason::term()}.
discover(Central, Device) ->
    case connect(Central, Device) of
	{ok, ConnRef} ->
	    case discover_services(Central, ConnRef) of
		{ok, Services} ->
		    %% fixme: make sure to pickup scan info!?
		    save(Device),
		    List = 
			[ 
			  case discover_characteristics(Central,ConnRef,Service) of 
			      {ok,Chars} ->
				  save(Device, Service, Chars),
				  Service#{characteristics=>Chars};
			       {error,_} ->
				  save(Device, Service),
				  Service
			  end || Service <- Services],
		    disconnect(Central, ConnRef),
		    {ok, List};
		Error ->
		    disconnect(Central, ConnRef),
		    Error
	    end;
	Error ->
	    Error
    end.

%% Save
%% cache/(public|private)/<bt-addr>/devinfo
%%
-spec save(Device::device()) ->
	  ok | {error, Reason::term()}.
save(Device) ->
    {AddrType, Addr} = get_type_and_addr(Device),
    StrAddr = lists:flatten(bt_util:format_address(Addr)),
    CacheDir = filename:join(code:priv_dir(?MODULE), "cache"),
    DevDir   = filename:join([CacheDir, AddrType, StrAddr]),
    ok = filelib:ensure_path(DevDir),
    DevInfoFilename = filename:join(DevDir, "devinfo"),
    DevData = io_lib:format("~p.\n", [Device]),
    R = file:write_file(DevInfoFilename, [DevData]),
    ?debug("Write file ~s [~w]\n", [DevInfoFilename, R]),
    R.

%%
%% Write Services and Characteristics to disk
%% cache/(public|private)/<bt-addr>/
%%     Service1 ... ServiceN (given with Full UUID string)
%%
-spec save(Device::device(), Service::service()) ->
	  ok | {error, Reason::term()}.
save(Device, Service) ->
    {AddrType, Addr} = get_type_and_addr(Device),
    StrAddr = lists:flatten(bt_util:format_address(Addr)),
    CacheDir = filename:join(code:priv_dir(?MODULE), "cache"),
    DevDir   = filename:join([CacheDir, AddrType, StrAddr]),
    ok = filelib:ensure_path(DevDir),
    ServiceUUID = bt_util:uuid_to_string(maps:get(uuid, Service)),
    ServiceFilename = filename:join(DevDir, ServiceUUID),
    ServiceChars = format_service(Service, "%%  "),
    ServiceData = io_lib:format("~p.\n", [Service]),
    R = file:write_file(ServiceFilename, [ServiceChars, ServiceData]),
    ?debug("Write file ~s [~w]\n", [ServiceFilename, R]),
    R.

%% Fixme write Service as directory? anc Chars as files?
save(Device, Service, Chars) ->
    {AddrType, Addr} = get_type_and_addr(Device),
    StrAddr = lists:flatten(bt_util:format_address(Addr)),
    CacheDir = filename:join(code:priv_dir(?MODULE), "cache"),
    DevDir   = filename:join([CacheDir, AddrType, StrAddr]),
    ok = filelib:ensure_path(DevDir),
    ?debug("Ensured path ~s\n", [DevDir]),
    ServiceUUID = bt_util:uuid_to_string(maps:get(uuid, Service)),
    ServiceFilename = filename:join(DevDir, ServiceUUID),
    %% Service1 = maps:put(characteristics, Chars, Service),
    ServiceChars = format_service(Service, "%%  "),
    ServiceData = io_lib:format("~p.\n", [Service]),
    CharsChars = [ format_characteristic(Char, "%%    ") ||
		     Char <- Chars],
    CharsData = io_lib:format("~p.\n", [Chars]),
    R = file:write_file(ServiceFilename, [ServiceChars, ServiceData, 
					  CharsChars, CharsData]),
    ?debug("Write file ~s [~w]\n", [ServiceFilename, R]),
    R.

get_type_and_addr(#{ addr := Addr, addr_type := Type }) ->
    {get_addrtype(Type), bt_util:getaddr(Addr)};
get_type_and_addr(#{ addr := Addr }) ->
    {public, bt_util:getaddr(Addr)};
get_type_and_addr(Addr) when ?is_bt_mac(Addr) ->
    {public, Addr};
get_type_and_addr(Addr) when is_list(Addr) ->
    {public, bt_util:getaddr(Addr)}.
    
get_addrtype(0) -> public;
get_addrtype(1) -> random;
get_addrtype(public) -> public;
get_addrtype(random) -> random;
get_addrtype(_) -> public.

%% @doc Find existing connection by address
find_connection_by_addr(AddrBin, State) ->
    maps:fold(
      fun(_Handle, #connection{ref = Ref, addr = Addr}, not_found)
            when Addr =:= AddrBin, Ref =/= undefined ->
              {ok, Ref};
         (_, _, Acc) ->
              Acc
      end, not_found, State#ble_state.connections).

%% @doc Internal: perform the actual connection
do_connect(Addr, AddrType, AddrBin, Timeout, From, State) ->
    ?debug("Connecting to BLE device ~p (type: ~p, timeout: ~wms)...",
           [Addr, AddrType, Timeout]),

    ConnOpts = #{
                 peer_addr_type => AddrType,
                 interval => {30, 50},
                 timeout => Timeout
                },
    case hci_le:create_connection(State#ble_state.hci, Addr, ConnOpts) of
        ok ->
            ?debug("Connection command sent, waiting for response...", []),
            %% Restore HCI filter after hci:call changed it
            restore_central_filter(State#ble_state.hci),
            %% Command sent successfully, now wait for connection complete event
            %% Store pending connection info so we can match it when event arrives
            TRef = erlang:send_after(Timeout, self(), {connect_timeout, AddrBin}),
            ?debug("send_after ~w connect_timeout ~w\n", [Timeout, AddrBin]),
            State#ble_state{pending_conn = {AddrBin, From, TRef}};
        Error ->
            ?error("Connection command failed: ~p", [Error]),
            restore_central_filter(State#ble_state.hci),
            From ! Error,
            State
    end.

-spec discover(Central::ble_handle(), Device::bt_mac()|device(),
	       ConnRef::ble_connection()) ->
	  {ok, [service()]} | {error, Reason::term()}.
discover(Central, Device, ConnRef) ->
    display_device(Device),
    {ok, Services} = discover_services(Central, ConnRef),
    display_services(Central, ConnRef, Services),
    {ok, Services}.

display_services(_Central, _ConnRef, []) -> ok;
display_services(_Central, _ConnRef, Services) ->
    io:format("+--+----------------------------------\n"),
    display_services_(_Central, _ConnRef, Services).

display_services_(Central, ConnRef, [Service]) ->
    display_service_(Central, ConnRef, Service),
    io:format("+--+----------------------------------\n");
display_services_(Central, ConnRef, [Service|Services]) ->
    display_service_(Central, ConnRef, Service),
    io:format("   +----------------------------------\n"), 
    display_services_(Central, ConnRef, Services).

display_service_(Central, ConnRef, Service) ->
    display_service(Service),
    case discover_characteristics(Central, ConnRef, Service) of 
	{ok,Chars} ->
	    display_characteristics(Chars);
	Error ->
	    io:format("Error reading Char = ~p\n", [Error])
    end.

display_devices([D|Ds]) ->
    display_device(D),
    display_devices(Ds);
display_devices([]) ->
    io:format("+-----------------------------------\n"),
    ok.

-spec display_device(Device::device()) -> 
	  ok.
display_device(D) ->
    Addr = maps:get(addr, D),
    RemoteName = case maps:get(name, D, undefined) of
		     undefined -> "Unknown";
		     Name0 -> Name0
		 end,
    Manuf = case bt_oui:manuf_from_addr(Addr) of
		{ok, M} -> M;
		false -> "Unknown"
	    end,
    Adv = maps:get(adv_data, D, []),
    Rssi = maps:get(rssi, D, 0),
    io:format("+-----------------------------------\n"),
    io:format("| Device: ~s\n", [bt_util:format_address(Addr)]),
    io:format("| Rssi: ~w\n", [Rssi]),
    io:format("| Name: ~s\n", [RemoteName]),
    io:format("| Manuf: ~s\n", [Manuf]),
    lists:foreach(
      fun ({name, _}) -> ok; %% display already
	  ({raw, _}) -> ok;  %% ignore
	  ({uuids, UUIDs}) ->
	      display_uuids(UUIDs);
	  ({Type, Value}) ->
	      io:format("| ~p: ~p\n", [Type, Value])
      end, Adv),
    ok.

display_uuids(UUIDs) ->
    lists:foreach(
      fun(UUID=?BT_UUID16(UUID16)) ->
	      case bt_db:lookup(service_uuids, UUID16) of
		  {ok, Object} ->
		      Name = maps:get(name, Object, "?"),
		      io:format("| Service16: ~s\n", [Name]);
		  _ ->
		      io:format("| Service16: ~s\n", 
				[bt_util:uuid_to_string(UUID)])
	      end;
	 (UUID=?BT_UUID32(_UUID32)) ->
	      io:format("| Service32: ~s\n", 
			[bt_util:uuid_to_string(UUID)]);
	 (UUID) ->
	      io:format("| Service128: ~s\n", 
			[bt_util:uuid_to_string(UUID)])
      end, UUIDs).

format_service(Service = #{ uuid := UUID }, Prefix) ->
    try uuid16(UUID) of
	UUID16 ->
	    Name = case bt_db:lookup(service_uuids, UUID16) of
		       {ok, Object} ->
			   proplists:get_value(<<"name">>, Object);
		       {error,enoent} ->
			   "Unknown";
		       {error,eninval} ->
			   "Invalid"
		   end,
	    [io_lib:format("~sSERV ~4.16.0B\n", [Prefix, UUID16]),
	     io_lib:format("~s~s\n",[Prefix,Name])]
    catch
	error:_ ->
	    []
    end ++ 
	[
	 io_lib:format("~s~s\n", [Prefix,bt_util:uuid_to_string(UUID)]),
	 io_lib:format("~sstart: ~w\n", [Prefix,maps:get(handle,Service,0)]),
	 io_lib:format("~sstop: ~w\n", [Prefix,maps:get(end_handle,Service,0)])
	].

display_service(Service) ->
    io:put_chars(format_service(Service, "   | ")).

display_characteristics([]) -> ok;
display_characteristics(Chars) ->
    io:format("   +--+--------------------------------\n"),
    display_characteristics_(Chars).

display_characteristics_([Char]) ->
    display_characteristic(Char),
    io:format("   +--+--------------------------------\n");
display_characteristics_([Char|Chars]) ->
    display_characteristic(Char),
    io:format("      +--------------------------------\n"),
    display_characteristics_(Chars).

format_characteristic(Char = #{ uuid := UUID }, Prefix) ->
    try uuid16(UUID) of
	UUID16 ->
	    Name = case bt_db:lookup(characteristic_uuids, UUID16) of
		       {ok, Object} ->
			   proplists:get_value(<<"name">>, Object);
		       {error, enoent} ->
			   "Unknown"
		   end,
	    [io_lib:format("~sCHAR ~4.16.0B\n", [Prefix,UUID16]),
	     io_lib:format("~s~s\n", [Prefix,Name])]
    catch
	error:_ ->
	    []
    end ++
	[io_lib:format("~s~s\n", [Prefix,bt_util:uuid_to_string(UUID)]),
	 io_lib:format("~shandle: ~w\n", [Prefix,maps:get(handle, Char, [])]),
	 io_lib:format("~svalue_handle: ~w\n", [Prefix,maps:get(value_handle, Char, [])]),
	 io_lib:format("~s~p\n", [Prefix,maps:get(properties, Char, [])])].

display_characteristic(Char) ->
    io:put_chars(format_characteristic(Char, "      | ")).

%%====================================================================
%% API - Setup
%%====================================================================

%% @doc Initialize BLE in Peripheral (server) mode with default name
-spec begin_peripheral() -> {ok, ble_handle()} | {error, term()}.
begin_peripheral() ->
    begin_peripheral(#{ name => "Erlang-BLE"}).

%% @doc Initialize BLE in Peripheral (server) mode
%% Like Arduino BLE.begin() but as peripheral
-spec begin_peripheral(Options::#{ atom() => term()}) -> {ok, ble_handle()} | {error, term()}.
begin_peripheral(Options) when is_map(Options) ->
    case maps:get(hci_channel, Options, ?DEFAULT_CHANNEL) of
        raw ->
            ble:reset_hci(Options),
            timer:sleep(1000);
        _ ->
            ok
    end,
    SELF = self(),
    Peripheral =
	spawn_link(
	  fun() ->
		  InterfaceName = get_interface_name(Options),
		  Channel = maps:get(hci_channel, Options, ?DEFAULT_CHANNEL),
		  {ok, Hci} = open_and_init_hci(InterfaceName, Options),
		  ?info("Peripheral using hci ~s (channel: ~p)\n", [InterfaceName, Channel]),
		  {ok, Size} = hci_le:read_buffer_size(Hci),
		  {ok, Features} = hci_le:read_local_supported_features(Hci),
		  %% Read local BD_ADDR for SMP
		  LocalAddr = case hci_api:read_bd_addr(Hci, ?HCI_NOEVENT, ?HCI_TIMEOUT) of
				  {ok, #read_bd_addr_rp{status = 0, bdaddr = Addr}} ->
				      ?info("Local BD_ADDR: ~s",
					    [bt_util:format_address(Addr)]),
				      Addr;
				  _ ->
				      ?warning("Could not read local BD_ADDR, using zero"),
				      <<0:48>>
			      end,
		  %% Get current filter first (for debugging)
		  {ok, Filter0} = bt_hci:get_filter(Hci),
		  ?debug("periheral orignal filter: ~p",
			 [bt_hci:decode_filter(Filter0)]),
		  AdvDecoder = maps:get(adv_decoder, Options, undefined),
		  AdvEncoder = maps:get(adv_encoder, Options, undefined),
		  State =
		      #ble_state{
			 mode = peripheral,
			 interface = InterfaceName,
			 hci = Hci,
			 hci_channel = Channel,
			 adv_decoder = AdvDecoder,
			 adv_encoder = AdvEncoder,
			 device_name = maps:get(device_name, Options,
						"Erlang-Ble"),
			 services = [],
			 local_addr = LocalAddr,
			 local_addr_type = 0,  %% Public address
			 size = Size,
			 features = Features
			},

		  %% Set LE event mask to receive connection events
		  ?debug("Setting LE event mask for peripheral..."),
		  %%                 
		  %% CONN_COMPLETE   00000010
		  %% ADV_REPORT      00000100
		  %% CONN_UPDATE     00001000
		  %% REMOTE_USED     00010000
		  %% LTK_REQUEST     00100000
		  ok = hci_le:set_event_mask(Hci,
					     [
					      ?EVT_LE_CONN_COMPLETE,
					      ?EVT_LE_LTK_REQUEST,
					      ?EVT_LE_ADVERTISING_REPORT,
					      ?EVT_LE_CONN_UPDATE_COMPLETE,
					      ?EVT_LE_READ_REMOTE_USED_FEATURES_COMPLETE,
					      ?EVT_LE_REMOTE_CONN_PARAM_REQUEST]),

		  %% Setup HCI filter to receive connection events and ACL data
		  Filter = bt_hci:make_filter(
			     any,  % All opcodes
			     [?HCI_EVENT_PKT, ?HCI_ACLDATA_PKT],  % Event and ACL data packets
			     [?EVT_CONN_COMPLETE,      %% Connection complete
			      ?EVT_DISCONN_COMPLETE,   %% Disconnection complete
			      ?EVT_ENCRYPT_CHANGE,     %% Encryption change (for pairing/bonding)
			      ?EVT_LE_META_EVENT]      %% LE meta events
			    ),
		  ?debug("New HCI filter: ~p",
			 [bt_hci:decode_filter(Filter)]),
		  case bt_hci:set_filter(Hci, Filter) of
		      ok ->
			  {ok, VerifiedFilter} = bt_hci:get_filter(Hci),
			  ?debug("HCI filter set for peripheral mode"),
			  ?debug("  Verified filter: ~p",
				 [bt_hci:decode_filter(VerifiedFilter)]),
			  SELF ! {self(), ok},
			  peripheral_loop(State);
		      {error, Reason} ->
			  ?error("Failed to set HCI filter: ~p", [Reason]),
			  SELF ! {self(), ok},
			  peripheral_loop(State)
		  end
	  end),
    receive
	{Peripheral, _Result} ->
	    {ok,Peripheral}
    end.

%% @doc Initialize BLE in Central (client) mode
-spec begin_central() -> {ok, ble_handle()} | {error, term()}.
begin_central() ->
    begin_central(#{}).

%% @doc Initialize BLE in Central (client) mode with options
-spec begin_central(Options::ble_options()) ->
	  {ok, ble_handle()} | {error, term()}.
begin_central(Options) ->
    case maps:get(hci_channel, Options, ?DEFAULT_CHANNEL) of
        raw ->
            reset_hci(Options),
            timer:sleep(1000);
        _ ->
            ok  % begin_central will do the init
    end,
    SELF = self(),
    Central =
	spawn_link(
	  fun() ->
		  InterfaceName = get_interface_name(Options),
		  Channel = maps:get(hci_channel, Options, ?DEFAULT_CHANNEL),
		  {ok, Hci} = open_and_init_hci(InterfaceName, Options),
		  ?info("Central using hci ~s (channel: ~p)\n",
		        [InterfaceName, Channel]),
		  {ok, Size} = hci_le:read_buffer_size(Hci),
		  {ok, Features} = hci_le:read_local_supported_features(Hci),
		  {ok, Filter0} = bt_hci:get_filter(Hci),
		  ?debug("central original filter: ~p",
			 [bt_hci:decode_filter(Filter0)]),
		  AdvDecoder = maps:get(adv_decoder, Options, undefined),
		  AdvEncoder = maps:get(adv_encoder, Options, undefined),
		  State = #ble_state{
			     mode = central,
			     interface = InterfaceName,
			     hci = Hci,
			     hci_channel = Channel,
			     adv_decoder = AdvDecoder,
			     adv_encoder = AdvEncoder,
			     services = [],
			     connections = #{},
			     conn_refs = #{},
			     size = Size,
			     features = Features
			    },
		  ?debug("Setting LE event mask for central..."),
		  ok = hci_le:set_event_mask(Hci,
					     [
					      ?EVT_LE_CONN_COMPLETE,
					      ?EVT_LE_LTK_REQUEST,
					      ?EVT_LE_ADVERTISING_REPORT,
					      ?EVT_LE_CONN_UPDATE_COMPLETE,
					      ?EVT_LE_READ_REMOTE_USED_FEATURES_COMPLETE,
					      ?EVT_LE_REMOTE_CONN_PARAM_REQUEST]),

		  %% Setup HCI filter for central mode
		  Filter = bt_hci:make_filter(
			     any,  % All opcodes
			     [?HCI_EVENT_PKT, ?HCI_ACLDATA_PKT],
			     all  % All events
			    ),

		  case bt_hci:set_filter(Hci, Filter) of
		      ok ->
			  {ok, VerifiedFilter} = bt_hci:get_filter(Hci),
			  ?debug("HCI filter set for central mode"),
			  ?debug("  Verified filter: ~p", 
				 [bt_hci:decode_filter(VerifiedFilter)]),
			  SELF ! {self(), ok},
			  central_loop(State);
		      {error, _Reason} ->
			  SELF ! {self(), ok},
			  central_loop(State)			  
		  end
	  end),
    receive
	{Central, _Result} ->
	    {ok,Central}
    end.


%% @doc Stop BLE and cleanup
-spec stop(Handle::ble_handle()) -> ok.
stop(Handle) when is_pid(Handle) ->
    Handle ! {stop, self()},
    receive
        {stopped, Handle} -> ok
    after 5000 ->
        exit(Handle, kill),
        ok
    end.

%%====================================================================
%% API - Peripheral (Server) Mode
%%====================================================================

%% @doc Set the device name for advertising
%% Like BLE.setLocalName("MyDevice")
-spec set_device_name(Handle::ble_handle(), Name::string()) -> ok.
set_device_name(Handle, DeviceName) when is_pid(Handle), is_list(DeviceName) ->
    Handle ! {set_device_name, DeviceName, self()},
    receive
        {ok, Handle} -> ok
    after 5000 ->
        {error, timeout}
    end.

%% @doc Add a GATT service (using 16-bit UUID shorthand)
%% Like BLE.addService("180D") for Heart Rate
-spec add_service(Handle::ble_handle(), UUID::uuid_string()) -> ok | {error, term()}.
add_service(Handle, UUID) ->
    add_service(Handle, UUID, primary).

%% @doc Add a GATT service with type (primary/secondary)
-spec add_service(Handle::ble_handle(), UUID::uuid_string(), Type::atom()) ->
    ok | {error, term()}.
add_service(Handle, UUID, Type) when is_pid(Handle) ->
    Handle ! {add_service, uuid(UUID), Type, self()},
    receive
        {ok, Handle} -> ok;
        {error, Reason} -> {error, Reason}
    after 5000 ->
        {error, timeout}
    end.

%% @doc Add a characteristic to the last added service
%% Properties: [read, write, notify, indicate]
%% Like: BLE.addCharacteristic("2A37", BLERead | BLENotify)
-spec add_characteristic(Handle::ble_handle(), UUID::uuid(),
                        Properties::char_properties(), InitialValue::binary()) ->
    ok | {error, term()}.
add_characteristic(Handle, UUID, Properties, InitialValue) ->
    add_characteristic(Handle, UUID, Properties, InitialValue, []).

%% @doc Add characteristic with descriptors
-spec add_characteristic(Handle::ble_handle(), UUID::uuid_string(),
                        Properties::char_properties(),
                        InitialValue::binary(), Descriptors::list()) ->
    ok | {error, term()}.
add_characteristic(Handle, UUID, Properties, InitialValue, Descriptors)
  when is_pid(Handle) ->
    Handle ! {add_characteristic, uuid(UUID), Properties,
              InitialValue, Descriptors, self()},
    receive
        {ok, Handle} -> ok;
        {error, Reason} -> {error, Reason}
    after 5000 ->
        {error, timeout}
    end.

%% @doc Start advertising
%% Like BLE.advertise()
-spec advertise(Handle::ble_handle()) -> ok | {error, term()}.
advertise(Handle) ->
    advertise(Handle, #{}).

%% @doc Start advertising with options
-spec advertise(Handle::ble_handle(), Options::adv_options()) ->
	  ok | {error, term()}.
advertise(Handle, Options) when is_pid(Handle), is_map(Options) ->
    Handle ! {advertise, Options, self()},
    receive
        {ok, Handle} -> ok;
        {error, Reason} -> {error, Reason}
    after 5000 ->
        {error, timeout}
    end.

%% @doc Set manufacturer advertising data
set_advertising_data(Handle, Data) ->
    Handle ! {set_advertising_data, Data, self()},
    receive
        {ok, Handle} -> ok;
        {error, Reason} -> {error, Reason}
    after 5000 ->
        {error, timeout}
    end.
    

%% @doc Stop advertising
-spec stop_advertising(Handle::ble_handle()) -> ok.
stop_advertising(Handle) when is_pid(Handle) ->
    Handle ! {stop_advertising, self()},
    receive
        {ok, Handle} -> ok
    after 5000 ->
        {error, timeout}
    end.

%%====================================================================
%% API - Central (Client) Mode
%%====================================================================

%% @doc Scan for BLE devices
%% Like BLE.scanForUuid("180D") but scans for all
-spec scan(Handle::ble_handle()) -> [device()].
scan(Handle) ->
    scan(Handle, 5000).

%% @doc Scan for BLE devices with timeout
-spec scan(Handle::ble_handle(), Timeout::timeout_ms()) -> [device()].
scan(Handle, Timeout) when is_pid(Handle), is_integer(Timeout) ->
    scan(Handle, Timeout, fun(_) -> true end).

-spec scan(Handle::ble_handle(), Timeout::timeout_ms(),
	   Filter::function()) ->  [device()].
scan(Handle, Timeout, Filter) when is_pid(Handle), is_integer(Timeout),
				   is_function(Filter, 1) ->
    Handle ! {scan, Timeout, Filter, self()},
    receive
        {scan_result, Devices} -> Devices
    after Timeout + 1000 ->
        {error, timeout}
    end.

%% @doc Connect to a BLE device
%% Like BLE.connect() after scan
-spec connect(Handle::ble_handle(), DeviceAddr::bt_mac()|device()) ->
	  {ok, ble_connection()} | {error, term()}.
connect(Handle, Addr) ->
    connect(Handle, Addr, ?DEFAULT_CONNECT_TIMEOUT).

%% @doc Connect to BLE device with timeout
-spec connect(Handle::ble_handle(), Addr::bt_mac()|device(), 
	      Timeout::timeout_ms()) ->
    {ok, reference()} | {error, term()}.
connect(Handle, Addr, Timeout) when is_pid(Handle) ->
    Handle ! {connect, Addr, Timeout, self()},
    receive
        {connected, ConnRef} -> {ok, ConnRef};
        {error, Reason} -> {error, Reason}
    after Timeout + 1000 ->
        {error, timeout}
    end.

%% @doc Disconnect from device
-spec disconnect(Handle::ble_handle(), ConnRef::reference()) -> ok.
disconnect(Handle, ConnRef) when is_pid(Handle), is_reference(ConnRef) ->
    Handle ! {disconnect, ConnRef, self()},
    receive
        {ok, Handle} -> ok
    after 5000 ->
        {error, timeout}
    end.

%% @doc Discover GATT services on connected device
-spec discover_services(Handle::ble_handle(), ConnRef::reference()) ->
    {ok, [map()]} | {error, term()}.
discover_services(Handle, ConnRef) when is_pid(Handle), is_reference(ConnRef) ->
    Handle ! {discover_services, ConnRef, self()},
    receive
        {services, Services} -> {ok, Services};
        {error, Reason} -> {error, Reason}
    after 20000 ->
        {error, timeout}
    end.

%% @doc Discover GATT characteristics on connected device
-spec discover_characteristics(Handle::ble_handle(), ConnRef::reference(),
			       Service::service()) ->
	  {ok, [characteristic()]} | {error, term()}.
discover_characteristics(Handle, ConnRef, Service) when is_pid(Handle), is_reference(ConnRef), is_map(Service)  ->
    Handle ! {discover_characteristics, ConnRef, self(), Service},
    receive
        {characteristics, Char} -> {ok, Char};
        {error, Reason} -> {error, Reason}
    after 20000 ->
        {error, timeout}
    end.

%%====================================================================
%% API - GATT Operations
%%====================================================================

%% @doc Read characteristic value (central)
-spec read(Handle::ble_handle(), ConnRef::handle(), CharUUID::uuid_string()) ->
    {ok, binary()} | {error, term()}.
read(Handle, ConnRef, CharUUID) when is_pid(Handle) ->
    Handle ! {read_char, ConnRef, uuid(CharUUID), self()},
    receive
        {value, Value} -> {ok, Value};
        {error, Reason} -> {error, Reason}
    after 5000 ->
        {error, timeout}
    end.

-spec read_handle(Handle::ble_handle(), ConnRef::handle(), ValueHandle::handle()) ->
    {ok, binary()} | {error, term()}.
read_handle(Handle, ConnRef, ValueHandle) when is_pid(Handle) ->
    Handle ! {read_handle, ConnRef, ValueHandle, self()},
    receive
        {value, Value} -> {ok, Value};
        {error, Reason} -> {error, Reason}
    end.

%% @doc Read current value 
-spec read_value(Handle::ble_handle(), ConnRef::handle(), 
		 CharUUID::uuid_string()) ->
	  {ok, binary()} | {error, term()}.
read_value(Handle, ConnRef, CharUUID) when is_pid(Handle) ->
    Handle ! {read_value, ConnRef, uuid(CharUUID), self()},
    receive
        {value, Value} -> {ok, Value};
        {error, Reason} -> {error, Reason}
    after 5000 ->
        {error, timeout}
    end.


%% @doc Write characteristic value (central)
-spec write(Handle::ble_handle(), ConnRef::handle(),
	    CharUUID::uuid(), Value::binary()) ->
    ok | {error, term()}.
write(Handle, ConnRef, CharUUID, Value) when is_pid(Handle), is_binary(Value) ->
    Handle ! {write_char, ConnRef, uuid(CharUUID), Value, self()},
    receive
        {ok, write_complete} -> ok;
        {error, Reason} -> {error, Reason}
    after 5000 ->
        {error, timeout}
    end.

%% @doc Write characteristic value (central)
-spec write_handle(Handle::ble_handle(), ConnRef::handle(),
		   ValueHandle::handle(), Value::binary()) ->
    ok | {error, term()}.
write_handle(Handle, ConnRef, ValueHandle, Value) when is_pid(Handle), is_binary(Value) ->
    Handle ! {write_handle, ConnRef, ValueHandle, Value, self()},
    receive
        {ok, write_complete} -> ok;
        {error, Reason} -> {error, Reason}
    after 5000 ->
        {error, timeout}
    end.


%% @doc Read current value (peripheral)
-spec read_value(Handle::ble_handle(), CharUUID::uuid()) ->
    {ok, binary()} | {error, term()}.
read_value(Handle, CharUUID) when is_pid(Handle) ->
    Handle ! {read_value, uuid(CharUUID), self()},
    receive
        {value, Value} -> {ok, Value};
        {error, Reason} -> {error, Reason}
    after 5000 ->
        {error, timeout}
    end.


%% @doc Write characteristic value (peripheral)
-spec write_value(Handle::ble_handle(), CharUUID::uuid(), Value::binary()) ->
    ok | {error, term()}.
write_value(Handle, CharUUID, Value) when is_pid(Handle), is_binary(Value) ->
    Handle ! {write_value, uuid(CharUUID), Value, self()},
    receive
        {ok, Handle} -> ok;
        {error, Reason} -> {error, Reason}
    after 5000 ->
        {error, timeout}
    end.


%% @doc Subscribe to characteristic notifications
%% Callback: fun(UUID, Value) -> ok end
-spec subscribe(Handle::ble_handle(), CharUUID::uuid(), Callback::function()) ->
    ok | {error, term()}.
subscribe(Handle, CharUUID, Callback) when is_pid(Handle), is_function(Callback) ->
    Handle ! {subscribe, uuid(CharUUID), Callback, self()},
    receive
        {ok, Handle} -> ok;
        {error, Reason} -> {error, Reason}
    after 5000 ->
        {error, timeout}
    end.

%% @doc Unsubscribe from notifications
-spec unsubscribe(Handle::ble_handle(), CharUUID::uuid()) -> ok.
unsubscribe(Handle, CharUUID) when is_pid(Handle) ->
    Handle ! {unsubscribe, uuid(CharUUID), self()},
    receive
        {ok, Handle} -> ok
    after 5000 ->
        {error, timeout}
    end.

%%====================================================================
%% API - Utility
%%====================================================================

uuid16(Value) when is_integer(Value), Value >= 0, Value =< 16#ffff ->
    Value;
uuid16(<<Value:16>>) ->
    Value;
uuid16(?BT_UUID16(Value)) ->
    Value.

%% @doc Convert various UUID formats to binary
-spec uuid(UUID::uuid_string()) -> uuid().
uuid(UUID) when is_binary(UUID), byte_size(UUID) =:= 16 ->
    UUID;
uuid(<<UUID:16>>) ->
    %% 16-bit UUID
    ?BT_UUID16(UUID);
uuid(UUID) when is_list(UUID), length(UUID) =:= 4 ->
    %% "180D" format
    Val = list_to_integer(UUID, 16),
    ?BT_UUID16(Val);
uuid(UUID) when is_atom(UUID) ->
    uuid(atom_to_list(UUID));
uuid(UUID) when is_list(UUID) ->
    bt_util:string_to_uuid(UUID).

%% @doc Pretty print device info
-spec print_device(Device::map()) -> ok.
print_device(#{addr := Addr} = Device) ->
    AddrStr = bt_util:format_address(Addr),
    Name = maps:get(name, Device, "Unknown"),
    RSSI = maps:get(rssi, Device, 0),
    %% io:format("~p\n", [Device]),
    io:format("Device: ~s (~s) RSSI: ~w dBm\n", [Name, AddrStr, RSSI]),
    ok.

%%====================================================================
%% API - Advanced HCI Management
%%====================================================================

%% @doc Reset HCI controller to clean state
%% Call this once at startup if needed, before creating any peripherals/centrals
%% Note: For hci_channel => user, reset is done automatically in begin_central/begin_peripheral
%% Example:
%%   1> ble:reset_hci().
%%   2> {ok, BLE} = ble:begin_peripheral("MyDevice").
-spec reset_hci() -> ok | {error, term()}.
reset_hci() ->
    reset_hci(#{}).

%% @doc Reset HCI with options
%% Options:
%%   disable_pairing => true  % Disable simple pairing (for testing)
%%   hci_channel => raw | user  % HCI channel (default: ?DEFAULT_CHANNEL)
%% Note: For USER channel, this is normally not needed as begin_central/begin_peripheral
%% will do the initialization automatically.
-spec reset_hci(Options::map()) -> ok | {error, term()}.
reset_hci(Options) ->
    InterfaceName = get_interface_name(Options),
    Channel = maps:get(hci_channel, Options, ?DEFAULT_CHANNEL),
    HciOptions = case Channel of
        user -> #{channel => user};
        raw ->  #{channel => raw}
    end,
    case hci:open(InterfaceName, HciOptions) of
        {ok, Hci} ->
            Result = do_hci_init(Hci, InterfaceName, Options),
            hci:close(Hci),
            Result;
        Error ->
            ?error("Failed to open HCI: ~p", [Error]),
            Error
    end.

%% @doc Internal: Open HCI and perform initialization if needed
%% For USER channel: does HCI reset, enables LE mode, sets event mask (on same socket)
%% For RAW channel: just opens the socket (use reset_hci separately if needed)
-spec open_and_init_hci(InterfaceName::string(), Options::map()) ->
    {ok, hci:handle()} | {error, term()}.
open_and_init_hci(InterfaceName, Options) ->
    Channel = maps:get(hci_channel, Options, ?DEFAULT_CHANNEL),
    HciOptions = 
	case Channel of
	    user -> #{channel => user};
	    raw -> #{ channel => raw}
	end,
    case hci:open(InterfaceName, HciOptions) of
        {ok, Hci} ->
            %% For USER channel, do initialization on this socket
            case Channel of
                user ->
                    case do_hci_init(Hci, InterfaceName, Options) of
                        ok -> {ok, Hci};
                        Error ->
                            hci:close(Hci),
                            Error
                    end;
                raw ->
                    {ok, Hci}
            end;
        Error ->
            Error
    end.

%% @doc Internal: Perform HCI initialization (reset, enable LE, set event mask)
-spec do_hci_init(Hci::hci:handle(), InterfaceName::string(), Options::map()) ->
    ok | {error, term()}.
do_hci_init(Hci, InterfaceName, Options) ->
    case hci_api:reset(Hci, ?HCI_NOEVENT, ?HCI_TIMEOUT) of
        {ok, <<0>>} ->
            ?debug("HCI ~s reset successful", [InterfaceName]),

            %% Enable LE mode
            ?debug("Enabling LE mode..."),
            case hci_api:write_le_host_supported(Hci, 1, 0, ?HCI_NOEVENT, ?HCI_TIMEOUT) of
                {ok, <<0>>} ->
                    ?debug("LE mode enabled");
                {ok, <<Status>>} ->
                    ?warning("Could not enable LE mode: ~p", [hci:decode_status(Status)]);
                Error ->
                    ?warning("Enabling LE mode: ~p", [Error])
            end,

            %% Set HCI event mask to include LE Meta Event
            ?debug("Setting HCI event mask for LE..."),
            EventMask = 16#20001FFFFFFFFFFF,  % Include LE Meta Event (bit 61)
            case hci_api:set_event_mask(Hci, <<EventMask:64/little>>, ?HCI_NOEVENT, ?HCI_TIMEOUT) of
                {ok, <<0>>} ->
                    ?debug("HCI event mask set");
                {ok, <<Status2>>} ->
                    ?warning("Could not set event mask: ~p", [hci:decode_status(Status2)]);
                Error2 ->
                    ?error("Error setting event mask: ~p", [Error2])
            end,

            %% Optionally disable pairing
            case maps:get(disable_pairing, Options, false) of
                true ->
                    ?debug("Disabling simple pairing..."),
                    case hci_api:write_simple_pairing_mode(Hci, 0, ?HCI_NOEVENT, ?HCI_TIMEOUT) of
                        {ok, <<0>>} ->
                            ?debug("Simple pairing disabled");
                        _ ->
                            ?warning("Could not disable pairing")
                    end;
                false ->
                    ok
            end,
            ok;
        {ok, <<Status>>} ->
            Error = hci:decode_status(Status),
            ?error("HCI reset failed: ~p", [Error]),
            {error, Error};
        Error ->
            ?error("HCI reset error: ~p", [Error]),
            Error
    end.

%%====================================================================
%% API - Security / LTK Management
%%====================================================================

%% @doc Set Long Term Key for a connection handle
%% This allows bonded devices to reconnect securely
%% Key must be a 16-byte binary
-spec set_ltk(Handle::ble_handle(), ConnHandle::integer(), Key::binary()) -> ok | {error, term()}.
set_ltk(Handle, ConnHandle, Key) when is_pid(Handle), is_integer(ConnHandle), is_binary(Key), byte_size(Key) =:= 16 ->
    Handle ! {set_ltk, ConnHandle, Key, self()},
    receive
        {ok, Handle} -> ok;
        {error, Reason} -> {error, Reason}
    after 5000 ->
        {error, timeout}
    end.

%% @doc Get Long Term Key for a connection handle
-spec get_ltk(Handle::ble_handle(), ConnHandle::integer()) -> {ok, binary()} | {error, term()}.
get_ltk(Handle, ConnHandle) when is_pid(Handle), is_integer(ConnHandle) ->
    Handle ! {get_ltk, ConnHandle, self()},
    receive
        {ltk, Key} -> {ok, Key};
        {error, Reason} -> {error, Reason}
    after 5000 ->
        {error, timeout}
    end.

%% @doc Clear/remove Long Term Key for a connection handle
-spec clear_ltk(Handle::ble_handle(), ConnHandle::integer()) -> ok.
clear_ltk(Handle, ConnHandle) when is_pid(Handle), is_integer(ConnHandle) ->
    Handle ! {clear_ltk, ConnHandle, self()},
    receive
        {ok, Handle} -> ok
    after 5000 ->
        {error, timeout}
    end.

%% @doc Accept all LTK requests (INSECURE - for testing only!)
%% This generates a zero-key and accepts any pairing request
-spec accept_all_ltk(Handle::ble_handle()) -> ok.
accept_all_ltk(Handle) when is_pid(Handle) ->
    Handle ! {accept_all_ltk, self()},
    receive
        {ok, Handle} -> ok
    after 5000 ->
        {error, timeout}
    end.

%% @doc Reject all LTK requests (default behavior)
-spec reject_all_ltk(Handle::ble_handle()) -> ok.
reject_all_ltk(Handle) when is_pid(Handle) ->
    Handle ! {reject_all_ltk, self()},
    receive
        {ok, Handle} -> ok
    after 5000 ->
        {error, timeout}
    end.

%%====================================================================
%% Internal - Peripheral Loop
%%====================================================================

%% @doc Handle incoming LE connection (BLE)
handle_le_connection_complete(Packet, State) ->
    try hci_api:decode_evt_le_conn_complete(Packet) of
        #evt_le_conn_complete{status = 0, handle = Handle,
                              peer_bdaddr = Addr, peer_bdaddr_type = AddrType} ->
            AddrStr = bt_util:format_address(Addr),
            ?info(""),
            ?info("=============================================="),
            ?info(" BLE Device Connected!"),
            ?info(" Address: ~s (type: ~w)", [AddrStr, AddrType]),
            ?info(" Handle: ~w", [Handle]),
            ?info("=============================================="),
            ?info(""),

            %% Add connection to state and start GATT server
            State1 = case gatt_server:start(State#ble_state.hci, Handle, State#ble_state.services, self()) of
                {ok, GattPid} ->
                    ?info("GATT Server started for handle ~w (PID: ~p)", [Handle, GattPid]),
                    Conn = #connection{handle = Handle, addr = Addr,
                                       addr_type = AddrType, gatt_server = GattPid},
                    NewConns = maps:put(Handle, Conn, State#ble_state.connections),
                    State#ble_state{connections = NewConns};
                {error, Reason} ->
                    ?error("Failed to start GATT server: ~p", [Reason]),
                    Conn = #connection{handle = Handle, addr = Addr, addr_type = AddrType},
                    NewConns = maps:put(Handle, Conn, State#ble_state.connections),
                    State#ble_state{connections = NewConns}
            end,

            %% In user channel mode, proactively send Security Request to initiate pairing
            %% This triggers the central (phone) to start SMP pairing
            case State1#ble_state.hci_channel of
                user ->
                    %% Small delay to let connection stabilize before security request
                    timer:sleep(50),
                    ?info("USER MODE: Sending SMP Security Request to initiate pairing"),
                    send_security_request(State1#ble_state.hci, Handle),
                    State1;
                _ ->
                    State1
            end;
        #evt_le_conn_complete{status = Status} ->
            ?error("BLE Connection failed: ~p", [hci:decode_status(Status)]),
            State
    catch
        _:Error ->
            ?error("Failed to decode LE connection event: ~p", [Error]),
            State
    end.

%% @doc Handle incoming classic BT connection (fallback)
handle_connection_complete(Packet, State) ->
    try hci_api:decode_evt_conn_complete(Packet) of
        #evt_conn_complete{status = 0, handle = Handle, bdaddr = Addr} ->
            AddrStr = bt_util:format_address(Addr),
            ?info(""),
            ?info("=============================================="),
            ?info(" Classic BT Device Connected!"),
            ?info(" Address: ~s", [AddrStr]),
            ?info(" Handle: ~w", [Handle]),
            ?info("=============================================="),
            ?info(""),
            %% Add connection to state
            Conn = #connection{handle = Handle, addr = Addr},
            NewConns = maps:put(Handle, Conn, State#ble_state.connections),
            State#ble_state{connections = NewConns};
        #evt_conn_complete{status = Status} ->
            ?error("Classic BT Connection failed: ~p",
		   [hci:decode_status(Status)]),
            State
    catch
        _:Error ->
            ?error("Failed to decode connection event: ~p", [Error]),
            State
    end.

%% @doc Handle ACL packet fragmentation/reassembly
%% PB Flag: 0 or 2 = first packet, 1 = continuation
handle_acl_fragment(ConnHandle, PBFlag, Data, State) when PBFlag =:= 0; PBFlag =:= 2 ->
    %% First packet of a new L2CAP PDU
    %% L2CAP header: Length (2 bytes, little-endian) + CID (2 bytes)
    case Data of
        <<L2capLen:16/little, _CID:16/little, _Payload/binary>> ->
            ExpectedTotal = L2capLen + 4,  %% L2CAP payload + header
            CurrentLen = byte_size(Data),
            if
                CurrentLen >= ExpectedTotal ->
                    %% Complete L2CAP PDU received in one packet
                    ?debug("ACL: Complete L2CAP PDU (~w bytes)", [CurrentLen]),
                    handle_acl_data(ConnHandle, Data, State);
                true ->
                    %% Need more fragments
                    ?debug("ACL: First fragment, expecting ~w bytes, got ~w",
                           [ExpectedTotal, CurrentLen]),
                    Buffer = maps:put(ConnHandle, {ExpectedTotal, Data},
                                      State#ble_state.acl_buffer),
                    State#ble_state{acl_buffer = Buffer}
            end;
        _ ->
            %% Malformed packet
            ?warning("ACL: Malformed first packet: ~p", [Data]),
            State
    end;
handle_acl_fragment(ConnHandle, 1, Data, State) ->
    %% Continuation fragment
    case maps:get(ConnHandle, State#ble_state.acl_buffer, undefined) of
        {ExpectedTotal, AccData} ->
            NewData = <<AccData/binary, Data/binary>>,
            CurrentLen = byte_size(NewData),
            ?debug("ACL: Continuation fragment, now have ~w/~w bytes",
                   [CurrentLen, ExpectedTotal]),
            if
                CurrentLen >= ExpectedTotal ->
                    %% L2CAP PDU complete
                    ?debug("ACL: L2CAP PDU complete (~w bytes)", [CurrentLen]),
                    Buffer = maps:remove(ConnHandle, State#ble_state.acl_buffer),
                    State1 = State#ble_state{acl_buffer = Buffer},
                    handle_acl_data(ConnHandle, NewData, State1);
                true ->
                    %% Still need more fragments
                    Buffer = maps:put(ConnHandle, {ExpectedTotal, NewData},
                                      State#ble_state.acl_buffer),
                    State#ble_state{acl_buffer = Buffer}
            end;
        undefined ->
            %% No buffer for this handle - orphan fragment
            ?warning("ACL: Orphan continuation fragment on handle ~w", [ConnHandle]),
            State
    end;
handle_acl_fragment(ConnHandle, PBFlag, Data, State) ->
    ?warning("ACL: Unknown PB flag ~w on handle ~w, data: ~p",
             [PBFlag, ConnHandle, Data]),
    State.

%% @doc Handle incoming ACL data (L2CAP/ATT packets for GATT)
%% Parse L2CAP header: Length (2) + CID (2) + Payload

handle_acl_data(ConnHandle, Data, State) ->
    case Data of
        <<_L2capLen:16/little, 16#00004:16/little, Payload/binary>> ->
            %% ATT channel (GATT)
	    ?debug("BLE: Got ATT data on handle ~w: ~p", [ConnHandle, Payload]),
	    %% Check if this is a response to a pending GATT request
	    case State#ble_state.mode of
		central ->
		    %% GATT Client: handle ATT response
		    gatt_client:handle_att_response(Payload, ConnHandle, State);
		peripheral ->
		    %% GATT Server: handle ATT request - forward to GATT server
		    case find_connection_by_handle(ConnHandle, State#ble_state.connections) of
			{ok, #connection{gatt_server = GattPid}} when is_pid(GattPid) ->
			    gatt_server:handle_att_request(GattPid, Payload, ConnHandle),
			    State;
			_ ->
			    %% No GATT server yet - we missed the LE_CONN_COMPLETE event!
			    %% Start GATT server now based on ACL data
			    ?info("Connection detected via ACL data on handle ~w, starting GATT server", [ConnHandle]),
			    case gatt_server:start(State#ble_state.hci, ConnHandle, State#ble_state.services, self()) of
				{ok, GattPid} ->
				    ?info("GATT Server started for handle ~w (PID: ~p)", [ConnHandle, GattPid]),
				    %% Forward this ATT request to the new server
				    gatt_server:handle_att_request(GattPid, Payload, ConnHandle),
				    %% Add connection to state
				    Conn = #connection{handle = ConnHandle,
						       gatt_server = GattPid},
				    NewConns = maps:put(ConnHandle, Conn, State#ble_state.connections),
				    State#ble_state{connections = NewConns};
				{error, Reason} ->
				    ?error("Failed to start GATT server: ~p", [Reason]),
				    State
			    end
		    end
	    end;
        <<_L2capLen:16/little, 16#00005:16/little, Payload/binary>> ->
            %% L2CAP signaling channel (LE)
	    ?debug("BLE: Got L2CAP LE signaling on handle ~w: ~p",
		 [ConnHandle, Payload]),
	    handle_l2cap_le_signaling(ConnHandle, Payload, State);
        <<_L2capLen:16/little, 16#00006:16/little, Payload/binary>> ->
	    %% SMP channel (Security Manager Protocol)
	    ?info("=== SMP (Pairing) Request ===", []),
	    ?debug("BLE: Got SMP pairing data on handle ~w", [ConnHandle]),
	    ?debug("SMP Payload: ~p", [Payload]),
	    ?debug("============================\n",[]),
	    handle_smp_data(ConnHandle, Payload, State);
        <<_L2capLen:16/little, Cid:16/little, Payload/binary>> ->
	    ?info("BLE: Got L2CAP data on CID 0x~4.16.0B, handle ~w, payload: ~p",
		 [Cid, ConnHandle, Payload]),
	    State
    end.


%% @doc Handle disconnection
handle_disconnection_complete(Packet, State) ->
    try hci_api:decode_evt_disconn_complete(Packet) of
        #evt_disconn_complete{status = 0, handle = Handle} ->
            ?info(" BLE Device Disconnected (handle: ~w)", [Handle]),
	    State;
        _ ->
            State
    catch
        _:Error ->
            ?error("Failed to decode disconnection event: ~p", [Error]),
            State
    end.

%% @doc Handle encryption change event
%% This is called after encryption has been enabled/disabled on a connection
handle_encryption_change(Packet, State) ->
    try hci_api:decode_evt_encrypt_change(Packet) of
	#evt_encrypt_change{status = Status, handle = Handle, encrypt = Encrypt} ->
	    case Status of
		0 ->
		    case Encrypt of
			0 ->
			    ?info("Encryption disabled on handle ~w", [Handle]);
			1 ->
			    ?info("Encryption enabled (E0/AES-CCM) on handle ~w", [Handle]);
			2 ->
			    ?info("Encryption enabled (AES-CCM) on handle ~w", [Handle]);
			_ ->
			    ?info("Encryption changed to mode ~w on handle ~w", [Encrypt, Handle])
		    end,
		    State;
		_ ->
		    ?error("Encryption change failed: status=~w, handle=~w", [Status, Handle]),
		    State
	    end
    catch
	_:Error ->
	    ?error("Failed to decode encryption change event: ~p", [Error]),
	    State
    end.

%% @doc Send LTK reply without blocking the event loop
%% Uses direct HCI send instead of hci:call to avoid filter changes and blocking
send_ltk_reply(Hci, Handle, LTK) ->
    %% Build the HCI command packet directly
    %% OGF_LE_CTL = 0x08, OCF_LE_LTK_REPLY = 0x001A
    hci:send(Hci, 16#08, 16#001A, <<Handle:16/little, LTK:16/binary>>).

%% @doc Handle LTK request event
%% This is called when:
%% 1. A device initiates encryption after SMP pairing (Random=0, Div=0 -> use STK)
%% 2. A previously bonded device attempts to reconnect (Random/Div from bonding)
handle_ltk_request(LePacket, State) ->
    try hci_api:decode_evt_le_long_term_key_request(LePacket) of
	#evt_le_long_term_key_request{handle = Handle, random = Random, diversifier = Div} ->
	    ?info("Got LTK request for handle ~w (Random: ~.16B, Div: ~w)",
		  [Handle, Random, Div]),

	    %% Check if this is an STK request (Random=0, Div=0) from current pairing
	    IsSTKRequest = (Random =:= 0) andalso (Div =:= 0),

	    case IsSTKRequest of
		true ->
		    %% This is requesting STK from current SMP pairing
		    handle_stk_request(Handle, State);
		false ->
		    %% This is requesting LTK from a previous bonding
		    handle_ltk_request_bonded(Handle, Random, Div, State)
	    end
    catch
	_:Error ->
	    ?error("Failed to decode LTK request: ~p", [Error]),
	    State
    end.

%% @doc Handle STK request (from current SMP pairing)
handle_stk_request(Handle, State) ->
    case maps:get(Handle, State#ble_state.stk_store, undefined) of
	undefined ->
	    %% No STK stored - pairing hasn't completed yet
	    %% Send negative reply to trigger the central to start SMP pairing
	    ?info("No STK for handle ~w - sending negative reply to trigger pairing", [Handle]),
	    hci_api:le_ltk_neg_reply(State#ble_state.hci, Handle,
				     ?HCI_NOEVENT, ?HCI_TIMEOUT),
	    State;
	STK ->
	    %% We have the STK from SMP pairing
	    ?info("Found STK for handle ~w from SMP pairing", [Handle]),
	    send_ltk_reply(State#ble_state.hci, Handle, STK),
	    ?info("STK reply sent successfully - encryption should start"),
	    State
    end.

%% @doc Handle LTK request for bonded device
handle_ltk_request_bonded(Handle, _Random, _Div, State) ->
    %% Check security mode
    case State#ble_state.ltk_mode of
	accept_all ->
	    %% In accept_all mode, check if we have a stored LTK first
	    case maps:get(Handle, State#ble_state.ltk_store, undefined) of
		undefined ->
		    %% Generate and store random LTK (for testing only!)
		    ?warning("TESTING MODE: Generating random LTK for handle ~w", [Handle]),
		    RandomLTK = crypto:strong_rand_bytes(16),
		    %% Send LTK reply directly without blocking
		    send_ltk_reply(State#ble_state.hci, Handle, RandomLTK),
		    ?info("Random LTK sent, storing for future use"),
		    NewStore = maps:put(Handle, RandomLTK, State#ble_state.ltk_store),
		    State#ble_state{ltk_store = NewStore};
		LTK ->
		    %% Use previously stored LTK
		    ?info("Found stored LTK for handle ~w (accept_all mode)", [Handle]),
		    %% Send LTK reply directly without blocking
		    send_ltk_reply(State#ble_state.hci, Handle, LTK),
		    ?info("Stored LTK sent"),
		    State
	    end;
	reject_all ->
	    %% Always reject
	    ?info("Rejecting LTK request (reject_all mode)"),
	    hci_api:le_ltk_neg_reply(State#ble_state.hci, Handle,
				     ?HCI_NOEVENT, ?HCI_TIMEOUT),
	    State;
	normal ->
	    %% Check if we have a stored LTK for this handle
	    case maps:get(Handle, State#ble_state.ltk_store, undefined) of
		undefined ->
		    %% No LTK stored - reject the request
		    ?info("No LTK stored for handle ~w - rejecting", [Handle]),
		    hci_api:le_ltk_neg_reply(State#ble_state.hci, Handle,
					     ?HCI_NOEVENT, ?HCI_TIMEOUT),
		    State;
		LTK ->
		    %% We have an LTK - provide it to the controller
		    ?info("Found LTK for handle ~w - accepting", [Handle]),
		    %% Send LTK reply directly without blocking
		    send_ltk_reply(State#ble_state.hci, Handle, LTK),
		    ?info("LTK reply sent successfully"),
		    State
	    end
    end.

%% @doc Handle SMP (Security Manager Protocol) data
handle_smp_data(ConnHandle, Payload, State) ->
    %% Get current SMP session for this connection
    Session = maps:get(ConnHandle, State#ble_state.smp_sessions, undefined),

    %% Get address info for SMP crypto
    Addresses = get_smp_addresses(ConnHandle, State),

    case ble_smp:handle_smp(Payload, ConnHandle, Session, Addresses) of
	{send, Response, NewSession} ->
	    %% Send SMP response and update session
	    send_smp_packet(State#ble_state.hci, ConnHandle, Response),
	    update_smp_session(ConnHandle, NewSession, State);

	{send_multi, Responses, NewSession} ->
	    %% Send multiple SMP packets (used by SC pairing)
	    lists:foreach(fun(R) ->
		send_smp_packet(State#ble_state.hci, ConnHandle, R)
	    end, Responses),
	    update_smp_session(ConnHandle, NewSession, State);

	{stk_ready, Response, NewSession} ->
	    %% STK calculated (Legacy pairing) - send response and store STK
	    send_smp_packet(State#ble_state.hci, ConnHandle, Response),
	    ?info("SMP: STK ready for handle ~w (Legacy)", [ConnHandle]),
	    STK = NewSession#smp_session.stk,
	    State1 = update_smp_session(ConnHandle, NewSession, State),
	    %% Store STK for upcoming LTK request
	    StkStore = maps:put(ConnHandle, STK, State1#ble_state.stk_store),
	    State1#ble_state{stk_store = StkStore};

	{sc_ltk_ready, Response, NewSession} ->
	    %% LTK calculated (SC pairing) - send response and store LTK
	    send_smp_packet(State#ble_state.hci, ConnHandle, Response),
	    ?info("SMP: SC Pairing complete for handle ~w", [ConnHandle]),
	    LTK = NewSession#smp_session.sc_ltk,
	    State1 = update_smp_session(ConnHandle, NewSession, State),
	    %% Store LTK (SC pairing generates LTK directly, no STK phase)
	    LtkStore = maps:put(ConnHandle, LTK, State1#ble_state.ltk_store),
	    %% Also store in STK for immediate use if needed
	    StkStore = maps:put(ConnHandle, LTK, State1#ble_state.stk_store),
	    State1#ble_state{ltk_store = LtkStore, stk_store = StkStore};

	{ltk, LTK, NewSession} ->
	    %% Received LTK from peer - store it
	    ?info("Storing received LTK for handle ~w", [ConnHandle]),
	    LtkStore = maps:put(ConnHandle, LTK, State#ble_state.ltk_store),
	    State1 = update_smp_session(ConnHandle, NewSession, State),
	    State1#ble_state{ltk_store = LtkStore};

	{master_id, EDIV, Rand, NewSession} ->
	    %% Received EDIV and Rand - store with LTK for identification
	    ?info("Received Master ID (EDIV: ~w, Rand: ~w) for handle ~w",
		  [EDIV, Rand, ConnHandle]),
	    %% TODO: Store EDIV/Rand with LTK for future matching
	    update_smp_session(ConnHandle, NewSession, State);

	{pairing_failed, _Reason, _NewSession} ->
	    %% Pairing failed - clear session
	    ?warning("SMP: Pairing failed for handle ~w", [ConnHandle]),
	    clear_smp_session(ConnHandle, State);

	{ok, NewSession} ->
	    %% Command handled successfully
	    update_smp_session(ConnHandle, NewSession, State);

	{error, Reason} ->
	    ?error("SMP error: ~p", [Reason]),
	    State;

	Other ->
	    ?warning("SMP: Unhandled result: ~p", [Other]),
	    State
    end.

%% @doc Get addresses for SMP crypto
get_smp_addresses(ConnHandle, State) ->
    %% Get peer address from connection
    {PeerAddr, PeerAddrType} =
	case maps:get(ConnHandle, State#ble_state.connections, undefined) of
	    #connection{addr = Addr, addr_type = Type}
	      when Addr =/= undefined ->
		{Addr, Type};
	    _ ->
		{<<0:48>>, 0}
	end,
    %% Get our local address
    LocalAddr = case State#ble_state.local_addr of
		    undefined -> <<0:48>>;
		    LA -> LA
		end,
    LocalAddrType = State#ble_state.local_addr_type,
    #{peer_addr => PeerAddr,
      peer_addr_type => PeerAddrType,
      local_addr => LocalAddr,
      local_addr_type => LocalAddrType}.

%% @doc Update SMP session for a connection
update_smp_session(ConnHandle, undefined, State) ->
    %% Remove session
    Sessions = maps:remove(ConnHandle, State#ble_state.smp_sessions),
    State#ble_state{smp_sessions = Sessions};
update_smp_session(ConnHandle, Session, State) ->
    Sessions = maps:put(ConnHandle, Session, State#ble_state.smp_sessions),
    State#ble_state{smp_sessions = Sessions}.

%% @doc Clear SMP session for a connection
clear_smp_session(ConnHandle, State) ->
    Sessions = maps:remove(ConnHandle, State#ble_state.smp_sessions),
    StkStore = maps:remove(ConnHandle, State#ble_state.stk_store),
    State#ble_state{smp_sessions = Sessions, stk_store = StkStore}.

%%====================================================================
%% L2CAP LE Signaling
%%====================================================================

%% L2CAP LE Signaling command codes
-define(L2CAP_COMMAND_REJECT,           16#01).
-define(L2CAP_CONN_PARAM_UPDATE_REQ,    16#12).
-define(L2CAP_CONN_PARAM_UPDATE_RSP,    16#13).

%% @doc Handle L2CAP LE signaling commands
handle_l2cap_le_signaling(ConnHandle, Payload, State) ->
    case Payload of
        <<Code:8, Identifier:8, Length:16/little, Data:Length/binary, _Rest/binary>> ->
            handle_l2cap_command(ConnHandle, Code, Identifier, Data, State);
        _ ->
            ?warning("Invalid L2CAP signaling payload: ~p", [Payload]),
            State
    end.

%% Connection Parameter Update Request
handle_l2cap_command(ConnHandle, ?L2CAP_CONN_PARAM_UPDATE_REQ, Identifier, Data, State) ->
    case Data of
        <<MinInterval:16/little, MaxInterval:16/little,
          Latency:16/little, Timeout:16/little>> ->
            ?info("L2CAP: Connection Parameter Update Request from handle ~w", [ConnHandle]),
            ?info("  Interval: ~w-~w (x1.25ms), Latency: ~w, Timeout: ~w (x10ms)",
                  [MinInterval, MaxInterval, Latency, Timeout]),

            %% Accept the request (result = 0x0000)
            %% We could also reject with 0x0001 if parameters are unacceptable
            Result = 16#0000,
            Response = <<?L2CAP_CONN_PARAM_UPDATE_RSP, Identifier:8,
                        2:16/little, Result:16/little>>,
            send_l2cap_signaling(State#ble_state.hci, ConnHandle, Response),
            ?info("L2CAP: Sent Connection Parameter Update Response (accepted)"),

            %% In user-mode HCI, we must explicitly tell the controller to update
            %% the connection parameters via HCI_LE_Connection_Update command.
            %% In raw mode, the kernel's Bluetooth stack handles this automatically.
            case State#ble_state.hci_channel of
                user ->
                    Hci = State#ble_state.hci,
                    MinCeLength = 0,  %% Minimum connection event length (0 = no preference)
                    MaxCeLength = 0,  %% Maximum connection event length (0 = no preference)
                    ?info("L2CAP: Sending HCI LE Connection Update to controller (user mode)"),
                    case hci_api:le_conn_update(Hci, ConnHandle,
                                                MinInterval, MaxInterval,
                                                Latency, Timeout,
                                                MinCeLength, MaxCeLength,
                                                -1, 5000) of
                        ok ->
                            ?info("L2CAP: HCI LE Connection Update command sent successfully");
                        {error, Reason} ->
                            ?warning("L2CAP: HCI LE Connection Update failed: ~p", [Reason])
                    end;
                raw ->
                    %% In raw mode, kernel handles connection parameter updates
                    ?debug("L2CAP: Connection parameter update handled by kernel (raw mode)")
            end,
            %% The actual parameter change will be confirmed via
            %% EVT_LE_CONN_UPDATE_COMPLETE event
            State;
        _ ->
            ?warning("Invalid Connection Parameter Update Request data: ~p", [Data]),
            State
    end;

%% Connection Parameter Update Response
handle_l2cap_command(ConnHandle, ?L2CAP_CONN_PARAM_UPDATE_RSP, _Identifier, Data, State) ->
    case Data of
        <<Result:16/little>> ->
            case Result of
                16#0000 ->
                    ?info("L2CAP: Connection Parameter Update accepted by peer (handle ~w)",
                          [ConnHandle]);
                16#0001 ->
                    ?warning("L2CAP: Connection Parameter Update rejected by peer (handle ~w)",
                             [ConnHandle]);
                _ ->
                    ?warning("L2CAP: Unknown Connection Parameter Update result: ~w", [Result])
            end;
        _ ->
            ?warning("Invalid Connection Parameter Update Response data: ~p", [Data])
    end,
    State;

%% Command Reject
handle_l2cap_command(ConnHandle, ?L2CAP_COMMAND_REJECT, _Identifier, Data, State) ->
    ?warning("L2CAP: Command Reject from handle ~w: ~p", [ConnHandle, Data]),
    State;

%% Unknown command
handle_l2cap_command(ConnHandle, Code, Identifier, Data, State) ->
    ?warning("L2CAP: Unknown signaling command 0x~2.16.0B from handle ~w", [Code, ConnHandle]),
    ?debug("  Identifier: ~w, Data: ~p", [Identifier, Data]),
    %% Send Command Reject
    Reason = 16#0000, %% Command not understood
    RejectData = <<Reason:16/little>>,
    Response = <<?L2CAP_COMMAND_REJECT, Identifier:8,
                (byte_size(RejectData)):16/little, RejectData/binary>>,
    send_l2cap_signaling(State#ble_state.hci, ConnHandle, Response),
    State.

%% @doc Handle LE Remote Connection Parameter Request (BLE 4.1+ LL-level request)
%% This is different from L2CAP Connection Parameter Update Request.
%% In user mode, we must respond with HCI command.
handle_le_remote_conn_param_request(LePacket, State) ->
    case LePacket of
        <<Handle:16/little, IntervalMin:16/little, IntervalMax:16/little,
          Latency:16/little, Timeout:16/little, _/binary>> ->
            ?info("LE Remote Connection Parameter Request (handle ~w)", [Handle]),
            ?info("  Interval: ~w-~w (x1.25ms), Latency: ~w, Timeout: ~w (x10ms)",
                  [IntervalMin, IntervalMax, Latency, Timeout]),

            case State#ble_state.hci_channel of
                user ->
                    %% In user mode, we must respond with HCI command
                    Hci = State#ble_state.hci,
                    MinCeLength = 0,
                    MaxCeLength = 0,
                    ?info("LE: Accepting connection parameter request (user mode)"),
                    %% Note: The timeout parameter is named 'Timeout' in the API
                    %% but it shadows the BIF timeout, so we use a different var name
                    case hci_api:le_remote_conn_param_req_reply(
                           Hci, Handle,
                           IntervalMin, IntervalMax,
                           Latency, Timeout,
                           MinCeLength, MaxCeLength,
                           undefined, 5000) of
                        {ok, _} ->
                            ?info("LE: Connection parameter request accepted");
                        {error, Reason} ->
                            ?warning("LE: Failed to accept conn param request: ~p", [Reason])
                    end;
                raw ->
                    %% In raw mode, kernel handles this automatically
                    ?debug("LE: Connection parameter request handled by kernel (raw mode)")
            end,
            State;
        _ ->
            ?warning("LE: Invalid Remote Connection Parameter Request data: ~p", [LePacket]),
            State
    end.

%% @doc Send L2CAP signaling packet
send_l2cap_signaling(Hci, ConnHandle, SignalingData) ->
    %% L2CAP header: Length (2) + CID (2)
    %% CID 0x0005 = LE signaling channel
    L2capLen = byte_size(SignalingData),
    L2capPdu = <<L2capLen:16/little, 16#0005:16/little, SignalingData/binary>>,

    %% ACL header: Handle+Flags (2) + Length (2)
    AclHandle = ConnHandle band 16#0FFF,
    AclFlags = 16#00,  %% First non-flushable packet
    AclHeader = <<(AclHandle bor (AclFlags bsl 12)):16/little,
                  (byte_size(L2capPdu)):16/little>>,

    AclPacket = <<?HCI_ACLDATA_PKT, AclHeader/binary, L2capPdu/binary>>,
    bt_hci:write(Hci, AclPacket).

%% @doc Send SMP packet over L2CAP channel 0x0006
%% Handles TX fragmentation for large packets
send_smp_packet(Hci, ConnHandle, SMPData) ->
    %% L2CAP header: Length (2) + CID (2)
    L2capLen = byte_size(SMPData),
    CID = 16#0006,  %% SMP channel
    L2capHeader = <<L2capLen:16/little, CID:16/little>>,
    L2capPdu = <<L2capHeader/binary, SMPData/binary>>,

    ?debug("Sending SMP packet on handle ~w: ~p (L2CAP PDU size: ~w)",
           [ConnHandle, SMPData, byte_size(L2capPdu)]),

    %% Fragment if needed (BLE default ACL MTU is 27 bytes for data portion)
    %% But most controllers support larger packets, so we try full packet first
    send_acl_pdu(Hci, ConnHandle, L2capPdu).

%% @doc Send L2CAP PDU, fragmenting if necessary
%% MaxPayload is typically 27 bytes for BLE LE-U
send_acl_pdu(Hci, ConnHandle, L2capPdu) ->
    %% BLE controllers typically support at least 27-251 bytes
    %% We'll use 251 (common BLE 4.2+ max) but fall back if needed
    MaxPayload = 251,
    send_acl_fragments(Hci, ConnHandle, L2capPdu, MaxPayload, first).

send_acl_fragments(_Hci, _ConnHandle, <<>>, _MaxPayload, _FragType) ->
    ok;
send_acl_fragments(Hci, ConnHandle, Data, MaxPayload, FragType) ->
    {Chunk, Rest} = case byte_size(Data) > MaxPayload of
        true -> split_binary(Data, MaxPayload);
        false -> {Data, <<>>}
    end,

    %% PB Flag: 2 (0b10) = First automatically-flushable packet
    %%          1 (0b01) = Continuing fragment
    PB = case FragType of
        first -> 2#10;  %% First automatically-flushable (standard for LE-U)
        continuation -> 2#01  %% Continuing fragment
    end,
    BC = 2#00,  %% Point-to-point (always 00 for LE)

    Handle = ConnHandle bor (PB bsl 12) bor (BC bsl 14),
    ACLLen = byte_size(Chunk),

    ACLPacket = <<?HCI_ACLDATA_PKT:8, Handle:16/little, ACLLen:16/little, Chunk/binary>>,

    ?debug("ACL TX: handle=~w, PB=~w, len=~w, remaining=~w",
           [ConnHandle, PB, ACLLen, byte_size(Rest)]),

    bt_hci:write(Hci, ACLPacket),

    %% Send remaining fragments
    NextFragType = case Rest of
        <<>> -> done;
        _ -> continuation
    end,
    case NextFragType of
        done -> ok;
        continuation -> send_acl_fragments(Hci, ConnHandle, Rest, MaxPayload, continuation)
    end.

%% @doc Send SMP Security Request to initiate pairing
%% This is sent by peripheral (slave) to request the central (master) to start pairing
%% SMP opcode 0x0B, payload is AuthReq byte
send_security_request(Hci, ConnHandle) ->
    %% AuthReq: SC (0x08) + Bonding (0x01) = 0x09
    %% Modern devices (like ESP32) typically require SC support
    AuthReq = 16#09,  %% SC + Bonding
    ?info("SMP: Sending Security Request with AuthReq=0x~2.16.0B (SC+Bonding)", [AuthReq]),
    SMPData = <<16#0B, AuthReq>>,  %% Security Request opcode + AuthReq
    send_smp_packet(Hci, ConnHandle, SMPData).


peripheral_loop(State) ->
    case bt_hci:read(State#ble_state.hci) of
	{ok, Event} ->
	    State1 = peripheral_event(Event, State),
	    peripheral_loop(State1);

	{error, eagain} ->
	    ok = bt_hci:select(State#ble_state.hci, read),
	    receive
		{select, Hci, _, ready_input} when
		      Hci =:= State#ble_state.hci ->
		    peripheral_loop(State);
		Command ->
		    case peripheral_command(Command, State) of
			stop ->
			    ?info("Peripheral loop stopped\n"),
			    stop;
			State1 ->
			    peripheral_loop(State1)
		    end
	    end;

	{error, Reason} ->
	    ?error("BLE Peripheral: HCI read error: ~p", [Reason]),
	    peripheral_loop(State)
    end.

%%
%% Process HCI events
%%			

peripheral_event(<<?HCI_EVENT_PKT, ?EVT_LE_META_EVENT, Len, Packet:Len/binary, _/binary>>, State) ->
    ?debug("Got LE_META_EVENT: ~p", [Packet]),
    case Packet of
	<<?evt_le_meta_event_bin(?EVT_LE_CONN_COMPLETE, _D1), LePacket/binary>> ->
	    ?debug("Got LE_CONN_COMPLETE"),
	    handle_le_connection_complete(LePacket, State);
	<<?evt_le_meta_event_bin(?EVT_LE_LTK_REQUEST, _D1), LePacket/binary>> ->
	    ?debug("Got LE_LTK_REQUEST (pairing request)"),
	    handle_ltk_request(LePacket, State);
	<<?evt_le_meta_event_bin(?EVT_LE_CONN_UPDATE_COMPLETE, _D1), LePacket/binary>> ->
	    case LePacket of
		<<Status, Handle:16/little, Interval:16/little,
		  Latency:16/little, SupervisionTimeout:16/little, _/binary>> ->
		    case Status of
			0 ->
			    ?info("BLE Peripheral: Connection parameters updated for handle ~w", [Handle]),
			    ?info("  New interval: ~.2f ms, latency: ~w, timeout: ~w ms",
				  [Interval * 1.25, Latency, SupervisionTimeout * 10]);
			_ ->
			    ?warning("BLE Peripheral: Connection parameter update failed, status: ~w (~s)",
				     [Status, hci:decode_status(Status)])
		    end;
		_ ->
		    ?warning("BLE Peripheral: Invalid LE_CONN_UPDATE_COMPLETE data")
	    end,
	    State;
	<<?evt_le_meta_event_bin(?EVT_LE_REMOTE_CONN_PARAM_REQUEST, _D1), LePacket/binary>> ->
	    %% Link Layer level connection parameter request (BLE 4.1+)
	    %% In user mode, we must respond with HCI command
	    handle_le_remote_conn_param_request(LePacket, State);
	<<SubEvent, _/binary>> ->
	    ?warning("Got other LE subevent: ~w", [SubEvent]),
	    State
    end;

%% Classic Bluetooth connection (fallback)
peripheral_event(<<?HCI_EVENT_PKT, ?EVT_CONN_COMPLETE, Len, Packet:Len/binary, _/binary>>, State) ->
    ?debug("HCI_EVENT_PKT: CONN_COMPLETE: ~p",[Packet]),
    State;

peripheral_event(<<?HCI_EVENT_PKT, ?EVT_DISCONN_COMPLETE, Len, Packet:Len/binary, _/binary>>, State) ->
    ?debug("HCI_EVENT_PKT: DISCONN_COMPLETE: ~p", [Packet]),
    handle_disconnection_complete(Packet, State);

peripheral_event(<<?HCI_EVENT_PKT, ?EVT_ENCRYPT_CHANGE, Len, Packet:Len/binary, _/binary>>, State) ->
    ?debug("HCI_EVENT_PKT: ENCRYPT_CHANGE: ~p", [Packet]),
    handle_encryption_change(Packet, State);

peripheral_event(<<?HCI_ACLDATA_PKT, Handle:16/little, Len:16/little, Data:Len/binary, _/binary>>, State) ->
    ConnHandle = Handle band 16#0fff,  %% Bits 0-11: Connection handle
    PBFlag = (Handle bsr 12) band 16#03,  %% Bits 12-13: Packet Boundary flag
    %% PB = 0: First non-automatically-flushable packet
    %% PB = 1: Continuing fragment
    %% PB = 2: First automatically-flushable packet
    handle_acl_fragment(ConnHandle, PBFlag, Data, State);
peripheral_event(Data,State) ->
    ?debug("BLE Peripheral: Got HCI data: ~p", [Data]),
    State.

peripheral_command({set_device_name, Name, From}, State) ->
    From ! {ok, self()},
    State#ble_state{device_name = Name};

peripheral_command({add_service, UUID, Type, From}, State) ->
    Service = #{uuid => UUID, type => Type, characteristics => []},
    NewServices = State#ble_state.services ++ [Service],
    From ! {ok, self()},
    State#ble_state{services = NewServices};

peripheral_command({add_characteristic, UUID, Props, Value, Descs, From},State) ->
    Char = #{uuid => UUID, properties => Props,
	     value => Value, descriptors => Descs},
    case State#ble_state.services of
	[] ->
	    From ! {error, no_service},
	    State;
	Services ->
	    [LastService | Rest] = lists:reverse(Services),
	    Chars = maps:get(characteristics, LastService, []),
	    UpdatedService = LastService#{characteristics => Chars ++ [Char]},
	    NewServices = lists:reverse([UpdatedService | Rest]),
	    From ! {ok, self()},
	    State#ble_state{services = NewServices}
    end;

peripheral_command({advertise, Options, From}, State) ->
    %% Start real BLE advertising!
    case start_advertising(State, Options) of
	ok ->
	    ?debug("BLE advertising started successfully!"),
	    From ! {ok, self()},
	    State#ble_state{advertising = true};
	{error, Reason} ->
	    ?debug("Failed to start advertising ~p", [Reason]),
	    From ! {error, Reason},
	    State
    end;
peripheral_command({set_advertising_data, Data, From}, State) ->
    From ! {ok, self()},
    State#ble_state{adv_manuf = Data};
peripheral_command({stop_advertising, From}, State) ->
    ?info("Stopping BLE advertising"),
    case State#ble_state.advertising of
	true ->
	    hci_api:le_set_advertise_enable(State#ble_state.hci, 0,
					    ?HCI_NOEVENT,?HCI_TIMEOUT),
	    ?info("BLE advertising stopped");
	false ->
	    ok
    end,
    From ! {ok, self()},
    State#ble_state{advertising = false};

peripheral_command({read_value, UUID, From}, State) ->
    case find_characteristic(UUID, State#ble_state.services) of
	error ->
	    From ! {error, not_found};
	Char ->
	    From ! {value, maps:get(value, Char)}
    end,
    State;

peripheral_command({write_value, UUID, Value, From}, State) ->
    case update_characteristic(UUID, Value, State#ble_state.services) of
	{ok, NewServices} ->
	    %% Update all connected GATT servers
	    lists:foreach(
		fun(#connection{gatt_server = GattPid}) when is_pid(GattPid) ->
			%% Update the value in GATT server's attribute table
			gatt_server:update_value(GattPid, UUID, Value),
			%% If characteristic has notify/indicate property, send notification
			case has_notify_property(UUID, NewServices) of
			    true ->
				?debug("Sending notification for UUID ~p", [UUID]),
				gatt_server:notify(GattPid, UUID, Value);
			    false ->
				ok
			end;
		   (_) -> ok
		end,
		maps:values(State#ble_state.connections)
	    ),
	    %% Call subscribers (local write from application)
	    call_subscribers(UUID, Value, local, State#ble_state.subscribers),
	    From ! {ok, self()},
	    State#ble_state{services = NewServices};
	error ->
	    From ! {error, not_found},
	    State
    end;
	
peripheral_command({set_ltk, ConnHandle, Key, From}, State) ->
    LtkStore = State#ble_state.ltk_store,
    NewLtkStore = maps:put(ConnHandle, Key, LtkStore),
    ?info("Stored LTK for handle ~w", [ConnHandle]),
    From ! {ok, self()},
    State#ble_state{ltk_store = NewLtkStore};

peripheral_command({get_ltk, ConnHandle, From}, State) ->
    case maps:get(ConnHandle, State#ble_state.ltk_store, undefined) of
	undefined ->
	    From ! {error, not_found};
	Key ->
	    From ! {ltk, Key}
    end,
    State;

peripheral_command({clear_ltk, ConnHandle, From}, State) ->
    LtkStore = State#ble_state.ltk_store,
    NewLtkStore = maps:remove(ConnHandle, LtkStore),
    ?info("Cleared LTK for handle ~w", [ConnHandle]),
    From ! {ok, self()},
    State#ble_state{ltk_store = NewLtkStore};

peripheral_command({accept_all_ltk, From}, State) ->
    ?warning("INSECURE MODE: Accepting all LTK requests with zero key!"),
    From ! {ok, self()},
    State#ble_state{ltk_mode = accept_all};

peripheral_command({reject_all_ltk, From}, State) ->
    ?info("Rejecting all LTK requests"),
    From ! {ok, self()},
    State#ble_state{ltk_mode = reject_all};

peripheral_command({subscribe, UUID, Callback, From}, State) ->
    Subscribers = State#ble_state.subscribers,
    CurrentSubs = maps:get(UUID, Subscribers, []),
    NewSubs = [Callback | CurrentSubs],
    NewSubscribers = maps:put(UUID, NewSubs, Subscribers),
    ?debug("Added subscriber for UUID ~p", [UUID]),
    From ! {ok, self()},
    State#ble_state{subscribers = NewSubscribers};

peripheral_command({unsubscribe, UUID, From}, State) ->
    Subscribers = State#ble_state.subscribers,
    NewSubscribers = maps:remove(UUID, Subscribers),
    ?debug("Removed all subscribers for UUID ~p", [UUID]),
    From ! {ok, self()},
    State#ble_state{subscribers = NewSubscribers};

peripheral_command({remote_write, UUID, Value}, State) ->
    ?debug("Remote write to UUID ~p: ~p", [UUID, Value]),
    %% Update our local service state
    case update_characteristic(UUID, Value, State#ble_state.services) of
	{ok, NewServices} ->
	    %% Call subscribers (remote write from connected device)
	    call_subscribers(UUID, Value, remote, State#ble_state.subscribers),
	    State#ble_state{services = NewServices};
	error ->
	    ?warning("Remote write to unknown UUID ~p", [UUID]),
	    State
    end;

peripheral_command({stop, From}, State) ->
    %% Stop advertising if active
    case State#ble_state.advertising of
	true ->
	    hci_api:le_set_advertise_enable(State#ble_state.hci, 0,
					    ?HCI_NOEVENT,?HCI_TIMEOUT);
	false ->
	    ok
    end,
    hci:close(State#ble_state.hci),
    From ! {stopped, self()},
    stop;

peripheral_command(Other, State) ->
    ?warning("Peripheral: Unknown command: ~p", [Other]),
    State.

%%====================================================================
%% Internal - Central Loop
%%====================================================================

central_loop(State) ->
    case bt_hci:read(State#ble_state.hci) of
	{ok, Event} ->
	    State1 = central_event(Event, State),
	    central_loop(State1);
	{error, eagain} ->
	    ok = bt_hci:select(State#ble_state.hci, read),
	    receive
		{select, Hci, _, ready_input} when
		      Hci =:= State#ble_state.hci ->
		    ?MODULE:central_loop(State);
		Command ->
		    %% Before processing command, drain any pending HCI events
		    State1 = drain_hci_events(State),
		    case central_command(Command, State1) of
			stop ->
			    ?info("Central loop stopped\n"),
			    stop;
			State2 ->
			    ?MODULE:central_loop(State2)
		    end
	    end;
	{error, Reason} ->
	    ?error("BLE Central: HCI read error: ~p", [Reason]),
	    ?MODULE:central_loop(State)
    end.

%% @doc Drain all pending HCI events before processing a command
drain_hci_events(State) ->
    case bt_hci:read(State#ble_state.hci) of
        {ok, Event} ->
            State1 = central_event(Event, State),
            drain_hci_events(State1);
        {error, eagain} ->
            State;
        {error, _Reason} ->
            State
    end.
	    
%% LE Meta Event (for BLE connections)	
central_event(<<?HCI_EVENT_PKT, ?EVT_LE_META_EVENT, Len, Packet:Len/binary, _/binary>>, State) ->
    ?debug("BLE Central: Got LE_META_EVENT: ~p", [Packet]),
    case Packet of
	<<?evt_le_meta_event_bin(?EVT_LE_CONN_COMPLETE, _D1), LePacket/binary>> ->
	    ?debug("BLE Central: Got LE_CONN_COMPLETE", []),
	    case hci_api:decode_evt_le_conn_complete(LePacket) of
		#evt_le_conn_complete{status = 0, handle = Handle, peer_bdaddr = Bdaddr} ->
		    AddrStr = bt_util:format_address(Bdaddr),
		    ?info("BLE Connection Complete!", []),
		    ?info(" Address: ~s", [AddrStr]),
		    ?info(" Handle: ~w", [Handle]),

		    %% Notify any pending connection request
		    case State#ble_state.pending_conn of
			{Bdaddr, From, TRef} when is_reference(TRef) ->
			    %% Normal case: cancel the timeout timer
			    ?info("Connection established"),
			    erlang:cancel_timer(TRef),
			    ConnRef = make_ref(),
			    Conn = #connection{ref = ConnRef, handle = Handle,
					       addr = Bdaddr},
			    Connections = State#ble_state.connections,
			    Connections1 = Connections#{ Handle => Conn },
			    ConnRefs = State#ble_state.conn_refs,
			    ConnRefs1 = ConnRefs#{ ConnRef => Handle },
			    From ! {connected, ConnRef},
			    State#ble_state{connections = Connections1,
					    conn_refs = ConnRefs1,
					    pending_conn = undefined};
			{Bdaddr, From, cancelling} ->
			    %% Connection succeeded AFTER we sent cancel!
			    %% This is actually a success - notify the caller
			    ?info("Connection succeeded after cancel (late success)", []),
			    ConnRef = make_ref(),
			    Conn = #connection{ref = ConnRef, handle = Handle,
					       addr = Bdaddr},
			    Connections = State#ble_state.connections,
			    Connections1 = Connections#{ Handle => Conn },
			    ConnRefs = State#ble_state.conn_refs,
			    ConnRefs1 = ConnRefs#{ ConnRef => Handle },
			    From ! {connected, ConnRef},
			    State#ble_state{connections = Connections1,
					    conn_refs = ConnRefs1,
					    pending_conn = undefined};
			_ ->
			    ?info("Connection was not ordered, ignored"),
			    %% Unsolicited connection, just add it
			    %% (no ignore it)
			    %%ConnRef = make_ref(),
			    %%Conn = #connection{ref = ConnRef, handle = Handle,
			    %% addr = Bdaddr},
			    %% NewConns = maps:put(Handle, Conn, State#ble_state.connections),
			    %% State#ble_state{connections = NewConns}
			    State
		    end;
		#evt_le_conn_complete{status = Status} ->
		    ?error("BLE Connection failed: ~p", [hci:decode_status(Status)]),
		    case State#ble_state.pending_conn of
			{_Addr, From, TRef} when is_reference(TRef) ->
			    %% Cancel the timeout timer
			    erlang:cancel_timer(TRef),
			    From ! {error, hci:decode_status(Status)},
			    State#ble_state{pending_conn = undefined};
			{_Addr, From, cancelling} ->
			    %% Cancel confirmed - connection really failed/cancelled
			    ?debug("Cancel confirmed, connection cancelled", []),
			    From ! {error, timeout},
			    State#ble_state{pending_conn = undefined};
			_ ->
			    State
		    end
	    end;
	<<?evt_le_meta_event_bin(?EVT_LE_LTK_REQUEST, _D1), LePacket/binary>> ->
	    ?debug("BLE Central: Got LE_LTK_REQUEST"),
	    handle_ltk_request(LePacket, State);
	<<?evt_le_meta_event_bin(?EVT_LE_CONN_UPDATE_COMPLETE, _D1), LePacket/binary>> ->
	    case LePacket of
		<<Status, Handle:16/little, Interval:16/little,
		  Latency:16/little, SupervisionTimeout:16/little, _/binary>> ->
		    case Status of
			0 ->
			    ?info("BLE Central: Connection parameters updated for handle ~w", [Handle]),
			    ?info("  New interval: ~.2f ms, latency: ~w, timeout: ~w ms",
				  [Interval * 1.25, Latency, SupervisionTimeout * 10]);
			_ ->
			    ?warning("BLE Central: Connection parameter update failed, status: ~w (~s)",
				     [Status, hci:decode_status(Status)])
		    end;
		_ ->
		    ?warning("BLE Central: Invalid LE_CONN_UPDATE_COMPLETE data")
	    end,
	    State;
	<<?evt_le_meta_event_bin(?EVT_LE_READ_REMOTE_USED_FEATURES_COMPLETE, _D1), _LePacket/binary>> ->
	    ?info("BLE Central: Read remote features complete"),
	    State;
	<<?evt_le_meta_event_bin(?EVT_LE_DATA_LENGTH_CHANGE, _D1), _LePacket/binary>> ->
	    ?info("BLE Central: Data length changed"),
	    State;
	<<?evt_le_meta_event_bin(?EVT_LE_PHY_UPDATE_COMPLETE, _D1), _LePacket/binary>> ->
	    ?info("BLE Central: PHY updated"),
	    State;
	<<?evt_le_meta_event_bin(?EVT_LE_REMOTE_CONN_PARAM_REQUEST, _D1), LePacket/binary>> ->
	    %% Link Layer level connection parameter request (BLE 4.1+)
	    %% In user mode, we must respond with HCI command
	    handle_le_remote_conn_param_request(LePacket, State);
	<<SubEvent, _/binary>> ->
	    ?warning("BLE Central: Unknown LE subevent ~w", [SubEvent]),
	    State
    end;

central_event(<<?HCI_ACLDATA_PKT, Handle:16/little, Len:16/little, Data:Len/binary, _/binary>>, State) ->
    ConnHandle = Handle band 16#0fff,  %% Bits 0-11: Connection handle
    PBFlag = (Handle bsr 12) band 16#03,  %% Bits 12-13: Packet Boundary flag
    ?debug("BLE Central: Got ACL data on handle ~w, PB=~w", [ConnHandle, PBFlag]),
    handle_acl_fragment(ConnHandle, PBFlag, Data, State);

%% Disconnection event
central_event(<<?HCI_EVENT_PKT, ?EVT_DISCONN_COMPLETE, Len, Packet:Len/binary, _/binary>> = RawEvent, State) ->
    ?debug("BLE Central: Raw disconnect event: ~p", [RawEvent]),
    case Packet of
        <<0, Handle:16/little, Reason>> ->
            ?warning("BLE Central: Remote disconnected (handle: ~w, reason: 0x~2.16.0B)",
                     [Handle, Reason]),
            %% Cancel any pending ATT operation for this handle
            State1 = cancel_pending_att_for_handle(Handle, disconnected, State),
            %% Clean up connection
            Connections1 = maps:remove(Handle, State1#ble_state.connections),
            %% Find and remove ConnRef
            ConnRefs1 = maps:filter(fun(_Ref, H) -> H =/= Handle end,
                                    State1#ble_state.conn_refs),
            State1#ble_state{connections = Connections1, conn_refs = ConnRefs1};
        <<Status, _/binary>> ->
            ?warning("BLE Central: Disconnect event with status ~w", [Status]),
            State
    end;

central_event(Data, State) ->
    ?debug("BLE Central: Got HCI data: ~p", [Data]),
    State.

central_command({scan, Timeout, Filter, From},State) ->
    %% Perform LE scan (BLE devices)
    ?info("Scanning for BLE devices (~w ms)...", [Timeout]),
    case perform_le_scan(State, Timeout, Filter) of
	{ok, Devices} ->
	    ?info("Found ~w BLE devices", [length(Devices)]),
	    From ! {scan_result, Devices};
	{error, Reason} ->
	    ?info("Scan failed: ~p", [Reason]),
	    From ! {scan_result, []}
    end,
    State;

central_command({connect, Addr0, Timeout, From}, State) ->
    %% Create LE connection
    %% Addr0 can be:
    %%   - A device map from scan (with addr and addr_type)
    %%   - A plain address tuple or string (defaults to public)
    {AddrType,Addr} = get_type_and_addr(Addr0),
    AddrBin = ?ADDR_TO_BIN(Addr),

    %% Check if we already have a connection to this address
    case find_connection_by_addr(AddrBin, State) of
        {ok, ConnRef} ->
            ?info("Already connected to ~s, returning existing connection",
                  [bt_util:format_address(AddrBin)]),
            From ! {ok, ConnRef},
            State;
        not_found ->
            %% Check if there's a pending connection attempt
            case State#ble_state.pending_conn of
                {AddrBin, _OldFrom, _} ->
                    ?warning("Connection already pending for ~s",
                             [bt_util:format_address(AddrBin)]),
                    From ! {error, connection_pending},
                    State;
                _ ->
                    do_connect(Addr, AddrType, AddrBin, Timeout, From, State)
            end
    end;

central_command({connect_timeout, AddrBin}, State) ->
    %% Connection timed out - cancel the pending connection
    case State#ble_state.pending_conn of
	{AddrBin, From, _TRef} ->
	    AddrStr = bt_util:format_address(AddrBin),
	    ?warning("Connection timeout for device ~s, sending cancel", [AddrStr]),

	    %% Cancel the ongoing connection attempt
	    %% We'll wait for LE_CONN_COMPLETE to confirm cancel or late success
	    case hci_le:cancel_connection(State#ble_state.hci) of
		ok ->
		    ?debug("Cancel sent, waiting for LE_CONN_COMPLETE", []),
		    %% Mark as cancelling - we wait for LE_CONN_COMPLETE
		    State#ble_state{pending_conn = {AddrBin, From, cancelling}};
		{error, Reason} ->
		    ?warning("Failed to cancel connection: ~p", [Reason]),
		    %% Cancel failed, give up immediately
		    From ! {error, timeout},
		    State#ble_state{pending_conn = undefined}
	    end;
	_ ->
	    %% Stale timeout, ignore
	    State
    end;

central_command({disconnect, ConnRef, From}, State) ->
    ?debug("ble.erl: {disconnect, ~p, ~p} received", [ConnRef, From]),
    case maps:get(ConnRef, State#ble_state.conn_refs, 0) of
	0 ->
	    From ! {error, not_found},
	    State;
	Handle ->
	    ?debug("ble.erl: disconnecting handle ~p", [Handle]),
	    %% Wait for EVT_DISCONN_COMPLETE to ensure proper disconnection
	    case hci_api:disconnect(State#ble_state.hci, Handle, 16#13,
				    ?EVT_DISCONN_COMPLETE, 5000) of
		{ok, #evt_disconn_complete{status = 0}} ->
		    ?info("Disconnected handle ~w", [Handle]),
		    From ! {ok, self()};
		{ok, #evt_disconn_complete{status = Status}} ->
		    ?warning("Disconnect failed with status ~w", [Status]),
		    From ! {ok, self()};  %% Still clean up locally
		{error, Reason} ->
		    ?warning("Disconnect error: ~p", [Reason]),
		    From ! {ok, self()}   %% Still clean up locally
	    end,
	    %% Restore HCI filter after hci:call changed it
	    restore_central_filter(State#ble_state.hci),
	    Connections1 = maps:remove(Handle, State#ble_state.connections),
	    ConnRefs1 = maps:remove(ConnRef, State#ble_state.conn_refs),
	    State#ble_state{connections = Connections1, conn_refs = ConnRefs1 }
    end;

central_command({discover_services, ConnRef, From}, State) ->
    case maps:get(ConnRef, State#ble_state.conn_refs, 0) of
	0 ->
	    From ! {error, not_found},
	    State;
	Handle ->
	    %% Send GATT service discovery request
	    case gatt_client:send_discover_services_request(State, Handle, From) of
		{ok, NewState} ->
		    NewState;
		{error, Reason} ->
		    From ! {error, Reason},
		    State
            end
    end;

central_command({discover_characteristics, ConnRef, From, Service}, State) ->
    case maps:get(ConnRef, State#ble_state.conn_refs, 0) of
	0 ->
	    From ! {error, not_found},
	    State;
	Handle ->
	    %% Send GATT service discovery request
	    ServHandle = maps:get(handle, Service, 0),
	    case gatt_client:send_discover_characteristics_request(State, Handle, From, ServHandle, Service) of
		{ok, NewState} ->
		    NewState;
		{error, Reason} ->
		    From ! {error, Reason},
		    State
	    end
    end;

central_command({read_char, ConnRef, UUID, From}, State) ->
    ConnHandle = maps:get(ConnRef, State#ble_state.conn_refs, 0),
    case maps:get(ConnHandle, State#ble_state.connections, undefined) of
	undefined ->
	    From ! {error, not_found},
	    State;
	#connection{ objects = Objects, uuids = UUIDs } ->
	    Handle = maps:get(UUID, UUIDs, 0),
	    Char = maps:get(Handle, Objects, #{}),
	    case maps:get(value_handle, Char, undefined) of 
		undefined ->
		    From ! {error, not_found},
		    State;
		ValueHandle ->
		    {ok,State1} = gatt_client:send_read_request(
				    State, ConnHandle, From, ValueHandle),
		    State1
	    end
    end;

central_command({read_handle, ConnRef, ValueHandle, From}, State) ->
    ConnHandle = maps:get(ConnRef, State#ble_state.conn_refs, 0),
    {ok,State1} = gatt_client:send_read_request(
		    State, ConnHandle, From, ValueHandle),
    State1;

central_command({write_char, ConnRef, UUID, Value, From}, State) ->
    ConnHandle = maps:get(ConnRef, State#ble_state.conn_refs, 0),
    case maps:get(ConnHandle, State#ble_state.connections, undefined) of
	undefined ->
	    From ! {error, not_found},
	    State;
	#connection{ objects = Objects, uuids = UUIDs } ->
	    Handle = maps:get(UUID, UUIDs, 0),
	    Char = maps:get(Handle, Objects, #{}),
	    case maps:get(value_handle, Char, undefined) of 
		undefined ->
		    From ! {error, not_found},
		    State;
		ValueHandle ->
		    {ok,State1} = gatt_client:send_write_request(
				    State, ConnHandle, From, ValueHandle,
				    Value),
		    State1
	    end
    end;

central_command({write_handle, ConnRef, ValueHandle, Value, From}, State) ->
    ConnHandle = maps:get(ConnRef, State#ble_state.conn_refs, 0),
    {ok,State1} = gatt_client:send_write_request(
		    State, ConnHandle, From, ValueHandle, Value),
    State1;

central_command({read_value, ConnRef, UUID, From}, State) ->
    ConnHandle = maps:get(ConnRef, State#ble_state.conn_refs, 0),
    case maps:get(ConnHandle, State#ble_state.connections, undefined) of
	undefined ->
	    From ! {error, not_found};
	#connection{ objects = Objects, uuids = UUIDs } ->
	    Handle = maps:get(UUID, UUIDs, 0),
	    Char = maps:get(Handle, Objects, #{}),
	    case maps:get(value, Char, undefined) of 
		undefined ->
		    From ! {error, not_found};
		Value ->
		    From ! {value, Value}
	    end
    end,
    State;


central_command({set_ltk, ConnHandle, Key, From}, State) ->
    LtkStore = State#ble_state.ltk_store,
    NewLtkStore = maps:put(ConnHandle, Key, LtkStore),
    ?info("Stored LTK for handle ~w", [ConnHandle]),
    From ! {ok, self()},
    State#ble_state{ltk_store = NewLtkStore};

central_command({get_ltk, ConnHandle, From}, State) ->
    case maps:get(ConnHandle, State#ble_state.ltk_store, undefined) of
	undefined ->
	    From ! {error, not_found};
	Key ->
	    From ! {ltk, Key}
    end,
    State;

central_command({clear_ltk, ConnHandle, From}, State) ->
    LtkStore = State#ble_state.ltk_store,
    NewLtkStore = maps:remove(ConnHandle, LtkStore),
    ?info("Cleared LTK for handle ~w", [ConnHandle]),
    From ! {ok, self()},
    State#ble_state{ltk_store = NewLtkStore};

central_command({accept_all_ltk, From}, State) ->
    ?warning("INSECURE MODE: Accepting all LTK requests with zero key!"),
    From ! {ok, self()},
    State#ble_state{ltk_mode = accept_all};

central_command({reject_all_ltk, From}, State) ->
    ?info("Rejecting all LTK requests"),
    From ! {ok, self()},
    State#ble_state{ltk_mode = reject_all};

central_command({stop, From}, State) ->
    ?debug("ble.erl: {stop, ~p} received, connections=~p",
	   [From, maps:keys(State#ble_state.connections)]),
    ?debug("ble.erl: caller stacktrace: ~p",
	   [try throw(x) catch _:_:ST -> ST end]),
    %% Disconnect all
    maps:foreach(fun(H, _Conn) ->
			 hci:disconnect(State#ble_state.hci, H, 16#13, 1000)
		 end, State#ble_state.connections),
    hci:close(State#ble_state.hci),
    From ! {stopped, self()},
    stop;

central_command({timeout, _TRef, att_timeout}, State) ->
    %% ATT operation timeout - handle retry or fail
    gatt_client:handle_att_timeout(State);

central_command({subscribe, UUID, Callback, From}, State) ->
    %% Subscribe to notifications for a characteristic (central mode)
    Subscribers = State#ble_state.subscribers,
    CurrentSubs = maps:get(UUID, Subscribers, []),
    NewSubs = [Callback | CurrentSubs],
    NewSubscribers = maps:put(UUID, NewSubs, Subscribers),
    ?debug("Central: Added subscriber for UUID ~p", [UUID]),
    From ! {ok, self()},
    State#ble_state{subscribers = NewSubscribers};

central_command({unsubscribe, UUID, From}, State) ->
    Subscribers = State#ble_state.subscribers,
    NewSubscribers = maps:remove(UUID, Subscribers),
    ?debug("Central: Removed all subscribers for UUID ~p", [UUID]),
    From ! {ok, self()},
    State#ble_state{subscribers = NewSubscribers};

central_command(Command, State) ->
    ?warning("Central: Unknown command: ~p", [Command]),
    State.


%%====================================================================
%% Internal Helpers
%%====================================================================

%% @doc Cancel pending ATT operation if it's for the given handle
cancel_pending_att_for_handle(Handle, Reason, State) ->
    case State#ble_state.pending_att of
        undefined ->
            State;
        #att_request{conn_handle = ConnHandle, timer_ref = TRef} = Request
          when ConnHandle =:= Handle ->
            erlang:cancel_timer(TRef),
            gatt_client:fail_pending_request(Request, Reason),
            State#ble_state{pending_att = undefined};
        _ ->
            State
    end.

%%====================================================================
%% Internal Helpers (continued)
%%====================================================================

%% @doc Restore HCI filter for central mode after hci:call changed it
restore_central_filter(Hci) ->
    Filter = bt_hci:make_filter(
               any,  % All opcodes
               [?HCI_EVENT_PKT, ?HCI_ACLDATA_PKT],
               all   % All events
              ),
    bt_hci:set_filter(Hci, Filter).

find_connection_by_handle(Handle, Connections) when is_map(Connections) ->
    case maps:get(Handle, Connections, undefined) of
	undefined ->
	    error;
	Conn ->
	    {ok, Conn}
    end.

%% @doc Call all subscribers for a given UUID with the new value
%% Origin is 'local' (app wrote value) or 'remote' (remote device wrote/notified)
-spec call_subscribers(uuid(), binary(), local | remote, map()) -> ok.
call_subscribers(UUID, Value, Origin, Subscribers) ->
    case maps:get(UUID, Subscribers, []) of
	[] ->
	    ok;
	Callbacks ->
	    lists:foreach(
		fun(Callback) ->
			try
			    Callback(UUID, Value, Origin)
			catch
			    _:Error ->
				?warning("Subscriber callback failed: ~p", [Error])
			end
		end,
		Callbacks
	    )
    end.

-spec find_characteristic(UUID::uuid(), [service()]) -> 
	  error | Char::characteristic().
find_characteristic(UUID, Services) when is_list(Services) ->
    find_characteristic_(uuid(UUID), Services);
find_characteristic(UUID, Service) when is_map(Service) ->
    find_characteristic_(uuid(UUID), [Service]).

find_characteristic_(_UUID, []) ->
    error;
find_characteristic_(UUID, [Service | Rest]) ->
    Chars = maps:get(characteristics, Service, []),
    case bt_util:maps_find(UUID, uuid, Chars) of
	false ->
            find_characteristic_(UUID, Rest);
	Char -> Char
    end.

update_characteristic(UUID, Value, Services) ->
    update_characteristic(UUID, Value, Services, []).

update_characteristic(_UUID, _Value, [], _Acc) ->
    error;
update_characteristic(UUID, Value, [Service | Rest], Acc) ->
    Chars = maps:get(characteristics, Service, []),
    case update_char_in_list(UUID, Value, Chars) of
        {ok, NewChars} ->
            NewService = Service#{characteristics => NewChars},
            {ok, lists:reverse(Acc) ++ [NewService | Rest]};
        error ->
            update_characteristic(UUID, Value, Rest, [Service | Acc])
    end.

update_char_in_list(UUID, Value, Chars) ->
    update_char_in_list(UUID, Value, Chars, []).

update_char_in_list(_UUID, _Value, [], _Acc) ->
    error;
update_char_in_list(UUID, Value, [Char | Rest], Acc) ->
    case maps:get(uuid, Char) of
        UUID ->
            NewChar = Char#{value => Value},
            {ok, lists:reverse(Acc) ++ [NewChar | Rest]};
        _ ->
            update_char_in_list(UUID, Value, Rest, [Char | Acc])
    end.

%% @doc Check if a characteristic has notify or indicate property
has_notify_property(UUID, Services) ->
    case find_characteristic_(UUID, Services) of
        error ->
            false;
        Char ->
            Props = maps:get(properties, Char, []),
            lists:member(notify, Props) orelse lists:member(indicate, Props)
    end.

%%====================================================================
%% Internal - BLE Scanning
%%====================================================================

%% @doc Perform LE scan for BLE devices
perform_le_scan(State, Timeout, Filter) ->
    %% Set scan parameters
    ScanOpts = 
	#{
	  type => active,      % Active scanning (request scan responses)
	  interval => 100,     % 100ms
	  window => 50,        % 50ms
	  own_addr_type => public
	 },
    Hci = State#ble_state.hci,
    {ok, Filter0} = bt_hci:get_filter(Hci),
    ?debug("scan using filters: ~p",
	   [bt_hci:decode_filter(Filter0)]),

    case hci_le:set_scan_parameters(Hci, ScanOpts) of
        ok ->
            %% Enable scanning
            case hci_le:set_scan_enable(Hci, true, true) of
                ok ->
		    ok = hci_le:set_event_mask(Hci,
					       [
						?EVT_LE_ADVERTISING_REPORT,
						?EVT_LE_CONN_COMPLETE,
						?EVT_LE_CONN_UPDATE_COMPLETE,
						?EVT_LE_READ_REMOTE_USED_FEATURES_COMPLETE,
						?EVT_LE_REMOTE_CONN_PARAM_REQUEST
					       ]),
		    ScanFilter = bt_hci:make_filter(any,[?HCI_EVENT_PKT],
						    [?EVT_LE_META_EVENT]),
		    ?debug("Setting scan filter: ~p", [bt_hci:decode_filter(ScanFilter)]),
		    bt_hci:set_filter(Hci, ScanFilter),
		    
                    %% Collect scan results for Timeout ms
                    StartTime = erlang:monotonic_time(millisecond),
                    Devices = collect_scan_results(State, StartTime, 
						   Timeout, #{}),
                    %% Disable scanning
                    hci_le:set_scan_enable(Hci, false, false),

                    %% Restore original filter
                    bt_hci:set_filter(Hci, Filter0),

                    %% Convert device map to list
                    DeviceList = 
			maps:fold(
			  fun(_Addr, DeviceInfo, Acc) ->
				  [DeviceInfo | Acc]
			  end, [], Devices),
		    {ok, 
		     lists:filter(
		       fun(Device) ->
			       Adv = maps:get(adv_data, Device, []),
			       filter_advertising_report(Adv, Filter)
		       end, DeviceList)};
                Error ->
                    Error
            end;
        Error ->
            Error
    end.

%% @doc Collect LE advertising reports from HCI events
%% Returns a map of {Address => DeviceInfo}
collect_scan_results(State, StartTime, Timeout, Devices) ->
    Hci = State#ble_state.hci,
    case bt_hci:read(Hci) of
	{ok, Event} ->
	    collect_event(State, Event, StartTime, Timeout, Devices);
	{error, eagain} ->
	    Now = erlang:monotonic_time(millisecond),
	    Remaining = Timeout - (Now - StartTime),
	    if Remaining =< 0 ->
		    Devices;
	       true ->
		    ok = bt_hci:select(Hci, read),
		    receive
			{select, Hci, _, ready_input} ->
			    collect_scan_results(State, StartTime, Timeout,
						 Devices)
		    after min(Remaining, 100) ->
			    collect_scan_results(State, StartTime, Timeout, 
						 Devices)
		    end
	    end;
	{error, Reason} ->
	    ?error("Reading HCI: ~p", [Reason]),
	    %% Error reading, continue anyway
	    collect_scan_results(State, StartTime, Timeout, Devices)
    end.

collect_event(State, Event, StartTime, Timeout, Devices) ->
    case Event of
	<<?HCI_EVENT_PKT,?EVT_LE_META_EVENT,Len,Packet:Len/binary,_/binary>> ->
	    ?debug("Got LE_META_EVENT, len=~w, packet=~p", [Len, Packet]),
	    %% Parse LE meta event
	    case Packet of
		<<?evt_le_meta_event_bin(?EVT_LE_ADVERTISING_REPORT, _D1), 
		  LePacket/binary>> ->
		    ?debug("Got ADVERTISING_REPORT, data=~p", [LePacket]),
		    %% Parse advertising report
		    Decoder = State#ble_state.adv_decoder,
		    UpdatedDevices = parse_advertising_reports(LePacket, 
							       Devices,
							       Decoder),
		    ?info("Now have ~w devices", [maps:size(UpdatedDevices)]),
		    collect_scan_results(State, StartTime, Timeout, UpdatedDevices);
		<<?evt_le_meta_event_bin(SubEvt, _D1), _LePacket/binary>> ->
		    ?debug("Got LE subevent ~w (not advertising report)", [SubEvt]),
		    %% Other LE event, ignore
		    collect_scan_results(State, StartTime, Timeout, Devices)
	    end;
	_ ->
	    ?debug("collect_event: got other event ~p", [Event]),
	    collect_scan_results(State, StartTime, Timeout, Devices)
    end.

%% @doc Parse LE advertising report packet
%% Multiple reports can be in one packet
%% HCI format (arrays, not interleaved):
%%   Num_Reports (1 byte)
%%   Event_Type[0..N-1] (N bytes)
%%   Address_Type[0..N-1] (N bytes)
%%   Address[0..N-1] (N*6 bytes)
%%   Length_Data[0..N-1] (N bytes)
%%   Data[0..N-1] (variable, sum of Length_Data[i] bytes)
%%   RSSI[0..N-1] (N bytes)
parse_advertising_reports(<<NumReports:8, Rest/binary>>,
			  Devices, Decoder) ->
    N = NumReports,
    case Rest of
	<<EvtTypes:N/binary, AddrTypes:N/binary, Addrs:(N*6)/binary,
	  LengthsAndDataAndRssi/binary>> ->
	    {Lengths, DataAndRssi} = split_binary(LengthsAndDataAndRssi, N),
	    TotalDataLen = lists:sum(binary_to_list(Lengths)),
	    case DataAndRssi of
		<<AllData:TotalDataLen/binary, RssiList:N/binary, _/binary>> ->
		    EvtTypeList = binary_to_list(EvtTypes),
		    AddrTypeList = binary_to_list(AddrTypes),
		    AddrList = split_addresses(Addrs, N),
		    LengthList = binary_to_list(Lengths),
		    RssiValues = [<<R:8/signed>> || <<R:8>> <= RssiList],
		    DataList = split_adv_data(AllData, LengthList),
		    Reports = zip6(EvtTypeList, AddrTypeList, AddrList,
				   LengthList, DataList, RssiValues),
		    process_advertising_reports(Reports, Devices, Decoder);
		_ ->
		    ?warning("incomplete advertising report data"),
		    Devices
	    end;
	_ ->
	    ?warning("malformed advertising report packet"),
	    Devices
    end.

zip6([A|As], [B|Bs], [C|Cs], [D|Ds], [E|Es], [F|Fs]) ->
    [{A,B,C,D,E,F} | zip6(As,Bs,Cs,Ds,Es,Fs)];
zip6([], [], [], [], [], []) ->
    [].

split_addresses(Bin, N) ->
    split_addresses(Bin, N, []).
split_addresses(_Bin, 0, Acc) ->
    lists:reverse(Acc);
split_addresses(<<Addr:6/binary, Rest/binary>>, N, Acc) ->
    split_addresses(Rest, N-1, [Addr|Acc]).

split_adv_data(Bin, Lengths) ->
    split_adv_data(Bin, Lengths, []).
split_adv_data(_Bin, [], Acc) ->
    lists:reverse(Acc);
split_adv_data(Bin, [Len|Lengths], Acc) ->
    <<Data:Len/binary, Rest/binary>> = Bin,
    split_adv_data(Rest, Lengths, [Data|Acc]).

process_advertising_reports(Reports, Devices, Decoder) ->
    NewDevices = build_new_devices(Reports, #{}, Decoder),
    merge_all_devices(NewDevices, Devices).

build_new_devices([], Acc, _Decoder) ->
    Acc;
build_new_devices([{EvtType, BdaddrType, Bdaddr, _Length, AdvData, <<Rssi:8/signed>>}|Rest],
		  Acc, Decoder) ->
    <<A:8, B:8, C:8, D:8, E:8, F:8>> = Bdaddr,
    AddrTuple = {F, E, D, C, B, A},
    Adv = ble_adv:decode(AdvData, Decoder),
    Name = ble_adv:get_name(Adv),
    NewInfo = #{
		addr => AddrTuple,
		addr_type => BdaddrType,
		evt_type => EvtType,
		rssi => Rssi,
		name => Name,
		adv_data => Adv
	       },
    UpdatedAcc = 
	case maps:find(AddrTuple, Acc) of
	    {ok, Existing} ->
		maps:put(AddrTuple, merge_device_info(Existing, NewInfo), Acc);
	    error ->
		maps:put(AddrTuple, NewInfo, Acc)
	end,
    build_new_devices(Rest, UpdatedAcc, Decoder).

%% Merge two device info maps
merge_device_info(Old, New) ->
    OldAdv = maps:get(adv_data, Old, []),
    NewAdv = maps:get(adv_data, New, []),
    MergedAdv = merge_adv_data(OldAdv, NewAdv),
    OldName = maps:get(name, Old, undefined),
    NewName = maps:get(name, New, undefined),
    Name = case NewName of
	       undefined -> OldName;
	       <<>> -> OldName;
	       _ -> NewName
	   end,
    New#{name => Name, adv_data => MergedAdv}.

%% Merge advertising data - new values override old with same key
%% uuids should be concatenated? (event in the same report? fixme)
merge_adv_data([{Key,Value1}|NewAdv], Adv) ->
    case lists:keytake(Key, 1, Adv) of
	{value, {uuids,Value0}, Adv1} ->
	    Value2 = Value1++Value0,
	    merge_adv_data(NewAdv, [{uuids,Value2}|Adv1]);
	{value, {raw,Value0}, Adv1} ->
	    Value2 = <<Value1/binary, Value0/binary>>,
	    merge_adv_data(NewAdv, [{raw,Value2}|Adv1]);
	{value, {Key,_Value0}, Adv1} ->
	    merge_adv_data(NewAdv, [{Key,Value1}|Adv1]);
	false ->
	    merge_adv_data(NewAdv, [{Key,Value1}|Adv])
    end;
merge_adv_data([], Adv) ->
    Adv.

%% Merge new devices into existing devices
merge_all_devices(NewDevices, ExistingDevices) ->
    maps:fold(
      fun(Addr, NewInfo, Acc) ->
	      case maps:find(Addr, Acc) of
		  {ok, Existing} ->
		      DeviceInfo = merge_device_info(Existing, NewInfo),
		      maps:put(Addr, DeviceInfo, Acc);
		  error ->
		       maps:put(Addr, NewInfo, Acc)
	      end
      end, ExistingDevices, NewDevices).

filter_advertising_report(Adv, Filter) ->
    try Filter(Adv) of
	true -> true;
	false -> false
    catch
	error:_ -> false
    end.

%%====================================================================
%% Internal - BLE Advertising
%%====================================================================

%% @doc Start BLE advertising with real HCI commands
start_advertising(State, AdvOptions) ->
    ?info("Starting BLE advertising: ~s", [State#ble_state.device_name]),
    Hci = State#ble_state.hci,
    Services = State#ble_state.services,
    %% Step 1: Set advertising parameters
    AdvParams = #{
        interval => maps:get(interval, AdvOptions, 500),  % 500ms default
        type => maps:get(type, AdvOptions, connectable),
        own_addr_type => public,
        channel_map => 7  % All channels
    },

    case hci_le:set_advertising_parameters(Hci, AdvParams) of
        ok ->
            %% Step 2: Build and set advertising data
            AdvData = build_advertising_data(State),
            case hci_le:set_advertising_data(Hci, AdvData) of
                ok ->
                    %% Step 3: Build and set scan response data (optional)
                    ScanData = build_scan_response_data(Services),
                    hci_le:set_scan_response_data(Hci, ScanData),

                    %% Step 4: Enable advertising
                    hci_le:set_advertise_enable(Hci, true);
                Error ->
                    Error
            end;
        Error ->
            Error
    end.

%% @doc Build BLE advertising data packet (max 31 bytes)
%% Format: [Length, Type, Data]
build_advertising_data(State) ->
    %% Flags (mandatory for LE)
    %% 0x06 = LE General Discoverable + BR/EDR Not Supported
    Flags = <<2, 16#01, 16#06>>,

    %% Complete Local Name
    DeviceName = State#ble_state.device_name,
    NameBin = list_to_binary(DeviceName),
    NameLen = byte_size(NameBin),
    Name = if NameLen =< 28 -> %% Leave room for flags
                   <<(NameLen + 1), 16#09, NameBin/binary>>;
              true -> %% Truncate if too long
                   <<29, 16#08, NameBin:28/binary>>
           end,
    %% Complete List of 16-bit Service UUIDs (if any)
    ServiceUUIDs = build_service_uuid_list(State#ble_state.services),
    
    Manuf = if State#ble_state.adv_manuf =/= undefined,
	       State#ble_state.adv_encoder =/= undefined ->
		    try apply(State#ble_state.adv_encoder, encode,
			      [State#ble_state.adv_manuf]) of
			Manu -> Manu
		    catch
			error:_ ->
			    <<>>
		    end;
	       true -> <<>>
	    end,

    %% Combine all AD structures
    Data = <<Flags/binary, Name/binary, ServiceUUIDs/binary, Manuf/binary>>,

    %% Truncate to 31 bytes if needed
    case byte_size(Data) of
        Size when Size =< 31 -> 
	    Data;
        Size ->
	    ?warning("Advertising data too big ~w\n", [Size]),
	    binary:part(Data, 0, 31)
    end.

%% @doc Build scan response data
build_scan_response_data(Services) ->
    %% Could include additional service UUIDs or manufacturer data
    %% For now, just leave empty
    case Services of
        [] -> <<>>;
        _ -> <<>>  % Could add more service info here
    end.

%% @doc Extract 16-bit service UUIDs from service list
build_service_uuid_list([]) ->
    <<>>;
build_service_uuid_list(Services) ->
    %% Extract 16-bit UUIDs
    UUIDs = lists:filtermap(
	      fun(Service) ->
		      case maps:get(uuid, Service) of
			  ?BT_UUID16(UUID16) ->
			      {true, <<UUID16:16/little>>};
			  _ ->
			      false
		      end
	      end, Services),
    case UUIDs of
        [] -> <<>>;
        _ ->
            UUIDsBin = iolist_to_binary(UUIDs),
            Len = byte_size(UUIDsBin),
            <<(Len + 1), 16#03, UUIDsBin/binary>>  % 0x03 = Complete List of 16-bit UUIDs
    end.

get_interface_name(Options) ->
    case maps:get(interface, Options, undefined) of
	undefined ->
	    case hci:get_devices() of
		[] -> undefined;
		[D|_] -> maps:get(name, D)
	    end;
	Name -> Name
    end.
