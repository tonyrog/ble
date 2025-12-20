%%%-------------------------------------------------------------------
%%% @doc
%%% LEGO Wireless Protocol Message Encoding/Decoding
%%% Handles Common Message Header and Message Types
%%% @end
%%%-------------------------------------------------------------------
-module(lego_messages).

%% API exports
-export([
	 decode_message/1,
	 decode_hub_attached_io/2,
	 decode_port_value/2,
	 decode_remote_button/1,

	 encode_message/1,
	 encode_hub_property_request/2,
	 encode_port_info_request/2,
	 encode_port_input_format_setup/3,
	 encode_port_input_format_setup/4,
	 encode_battery_request/0,
	 encode_button_request/0,
	 encode_enable_battery_updates/0,
	 encode_enable_button_updates/0,
	 encode_enable_port_notifications/1,
	 encode_enable_port_notifications/2,
	 encode_port_value_data/2,
	 encode_remote_button/1,

	 %% Network commands (for remote control handshake)
	 encode_network_command/2,
	 encode_family_set/1,
	 encode_connection_complete/0
]).


-include("lego_messages.hrl").

%%%===================================================================
%%% API
%%%===================================================================

%% @doc Decode a LEGO message

%% Handle escaped length encoding for messages > 127 bytes
decode_message(<<1:1,L0:7,L1:8,HubID:8, MessageType:8, Payload/binary>>) ->
    ActualLength = (L1 bsl 7) + L0,
    decode_message_by_type(MessageType, ActualLength, HubID, Payload);
decode_message(<<0:1,L0:7,HubID:8, MessageType:8, Payload/binary>>) ->
    ActualLength = L0,
    decode_message_by_type(MessageType, ActualLength, HubID, Payload);
decode_message(_) ->
    {error, invalid_message}.

decode_message_by_type(?MSG_HUB_ATTACHED_IO, _Len, HubID, Payload) ->
    decode_hub_attached_io(HubID, Payload);
decode_message_by_type(?MSG_PORT_VALUE_SINGLE, _Len, HubID, Payload) ->
    decode_port_value(HubID, Payload);
decode_message_by_type(?MSG_HUB_PROPERTIES, _Len, HubID, Payload) ->
    decode_hub_properties(HubID, Payload);
decode_message_by_type(?MSG_HW_NETWORK_COMMANDS, _Len, HubID, PayLoad) ->
    decode_hw_network_command(HubID, PayLoad);
decode_message_by_type(?MSG_GENERIC_ERROR, _Len, HubID, Payload) ->
    decode_error(HubID, Payload);
decode_message_by_type(Type, Len, HubID, Payload) ->
    {ok, #{
	   hub_id => HubID,
	   type => Type,
	   length => Len,	   
	   payload => Payload
    }}.

%% @doc Encode a LEGO message with common header
encode_message(#{type := Type, hub_id := HubID, payload := Payload}) ->
    PayloadBin = iolist_to_binary(Payload),
    Length = byte_size(PayloadBin) + 3, % +3 for Length, HubID, Type

    if
        Length =< 127 ->
            <<Length:8, HubID:8, Type:8, PayloadBin/binary>>;
        Length > 127 ->
            % Escaped length encoding
            LSB = (Length band 16#7F) bor 16#80,
            MSB = Length bsr 7,
            <<LSB:8, MSB:8, HubID:8, Type:8, PayloadBin/binary>>
    end.

%% @doc Encode a hub property request
encode_hub_property_request(Property, Operation) ->
    Payload = <<Property:8, Operation:8>>,
    encode_message(#{
		     type => ?MSG_HUB_PROPERTIES,
		     hub_id => 0,
		     payload => Payload
		    }).

%% @doc Request battery voltage
encode_battery_request() ->
    encode_hub_property_request(?PROP_BATTERY_VOLTAGE, ?OP_REQUEST_UPDATE).

%% @doc Request button state
encode_button_request() ->
    encode_hub_property_request(?PROP_BUTTON, ?OP_REQUEST_UPDATE).

%% @doc Enable battery voltage updates
encode_enable_battery_updates() ->
    encode_hub_property_request(?PROP_BATTERY_VOLTAGE, ?OP_ENABLE_UPDATES).

%% @doc Enable button updates (green hub button)
encode_enable_button_updates() ->
    encode_hub_property_request(?PROP_BUTTON, ?OP_ENABLE_UPDATES).

%% @doc Enable port input notifications (for remote control buttons etc)
%% PortID: 0 = left buttons, 1 = right buttons on remote
%% Mode: 0 = standard button mode
encode_enable_port_notifications(PortID) ->
    encode_enable_port_notifications(PortID, 0).

encode_enable_port_notifications(PortID, Mode) ->
    encode_port_input_format_setup(PortID, Mode, true).

%% @doc Encode port input format setup
%% This is used to enable/disable notifications for I/O ports
%% PortID: The port to configure
%% Mode: The sensor mode (0 for buttons)
%% NotificationEnabled: true to enable notifications
encode_port_input_format_setup(PortID, Mode, NotificationEnabled) ->
    encode_port_input_format_setup(PortID, Mode, 1, NotificationEnabled).

%% @doc Encode port input format setup with delta
%% Delta: minimum change threshold before notification (1 = every change)
encode_port_input_format_setup(PortID, Mode, Delta, NotificationEnabled) ->
    NotifyByte = case NotificationEnabled of
		     true -> 1;
		     false -> 0
		 end,
    Payload = <<PortID:8, Mode:8, Delta:32/little, NotifyByte:8>>,
    encode_message(#{
		     type => ?MSG_PORT_INPUT_FORMAT_SETUP,
		     hub_id => 0,
		     payload => Payload
		    }).

%% @doc Encode port information request
encode_port_info_request(PortID, InfoType) ->
    Payload = <<PortID:8, InfoType:8>>,
    encode_message(#{
		     type => ?MSG_PORT_INFO_REQUEST,
		     hub_id => 0,
		     payload => Payload
		    }).

%%%===================================================================
%%% Network Commands (for Remote Control handshake)
%%%===================================================================


%% @doc Encode a network command
%% Subcommand: The network subcommand type
%% Value: The value to send (family number, etc)
encode_network_command(Subcommand, Value) ->
    Payload = <<Subcommand:8, Value:8>>,
    encode_message(#{
		     type => ?MSG_HW_NETWORK_COMMANDS,
		     hub_id => 0,
		     payload => Payload
		    }).

%% @doc Set family ID to complete connection handshake
%% Family: 1-254 (0 and 255 are reserved)
%% Call this when you receive connection_request from the remote
encode_family_set(Family) ->
    encode_network_command(?NET_FAMILY_SET, Family).

%% @doc Complete sequence to accept remote connection
%% Returns a list of commands to send in order
encode_connection_complete() ->
    %% Set family to 1 (any non-zero value works)
    encode_family_set(1).

%%%===================================================================
%%% Decode Functions
%%%===================================================================

%% @doc Decode Hub Attached I/O message
decode_hub_attached_io(HubID, <<PortID:8, Event:8, Rest/binary>>) ->
    EventType = decode_io_event(Event),
    case EventType of
        detached ->
            {ok, #{
		   type => hub_attached_io,
		   hub_id => HubID,
		   port_id => PortID,
		   event => detached
		  }};
        attached ->
            <<IOTypeID:16/little, HWRev:32/little-signed,
              SWRev:32/little-signed>> = Rest,
            {ok, #{
		   type => hub_attached_io,
		   hub_id => HubID, 
		   port_id => PortID,
		   event => attached,
		   io_type_id => IOTypeID,
		   io_type_name => get_io_type_name(IOTypeID),
		   hw_revision => decode_version(HWRev),
		   sw_revision => decode_version(SWRev)
		  }};
        attached_virtual ->
            <<IOTypeID:16/little, PortIDA:8, PortIDB:8>> = Rest,
            {ok, #{
		   type => hub_attached_io,
		   hub_id => HubID, 
		   port_id => PortID,
		   event => attached_virtual,
		   io_type_id => IOTypeID,
		   io_type_name => get_io_type_name(IOTypeID),
		   port_id_a => PortIDA,
		   port_id_b => PortIDB
		  }};
	unknown ->
            {ok, #{
		   type => hub_attached_io,
		   hub_id => HubID, 
		   event => Event,
		   payload => Rest
		  }}
    end.

decode_io_event(16#00) -> detached;
decode_io_event(16#01) -> attached;
decode_io_event(16#02) -> attached_virtual;
decode_io_event(_) -> unknown.

%% @doc Decode port value message
decode_port_value(HubID, <<PortID:8, Value/binary>>) ->
    {ok, #{
	   hub_id => HubID,
	   type => port_value,
	   port_id => PortID,
	   value => Value,
	   decoded_value => decode_port_value_data(PortID, Value)
	  }}.

encode_port_value_data(PortID, Button) when is_atom(Button) ->
    Value = encode_remote_button(Button),
    <<PortID:8, Value:8/signed>>;
encode_port_value_data(PortID, Value) when is_integer(Value) ->
    <<PortID:8, Value:8/signed>>.

%% Decode button values for remote control ports (0 and 1)
decode_port_value_data(_PortID, <<ButtonValue:8/signed>>) ->
    decode_remote_button(ButtonValue);
decode_port_value_data(_PortID, Value) ->
    Value.

%% Remote control button values:
%%  0 = no button pressed
%%  1 = plus (+) button pressed
%% -1 = minus (-) button pressed
%%  127 = red center button pressed
%% Button release sends 0
decode_remote_button(0) -> released;
decode_remote_button(1) -> plus;
decode_remote_button(-1) -> minus;
decode_remote_button(127) -> red;
decode_remote_button(V) -> {unknown, V}.

encode_remote_button(released) -> 0;
encode_remote_button(plus) ->  1;
encode_remote_button(minus) -> -1;
encode_remote_button(red) -> 127.
     

%% @doc Decode hub properties message
decode_hub_properties(HubID, <<Property:8, Operation:8, Payload/binary>>) ->
    PropName = get_property_name(Property),
    {ok, #{
	   hub_id => HubID,
	   type => hub_properties,
	   property => PropName,
	   operation => decode_operation(Operation),
	   value => decode_property_value(PropName, Payload)
	  }}.

decode_hw_network_command(HubID, <<Type, Value, _/binary>>) ->
    {CommandType, Dir} = 
	case Type of
	    ?NET_CONNECTION_REQUEST -> {connection_request, up};
	    ?NET_FAMILY_SET -> {family_set, down};
	    ?NET_FAMILY -> {family, up};
	    ?NET_SUBFAMILY -> {sub_family, up};
	    ?NET_SUBFAMILY_SET -> {sub_family_set, down};
	    ?NET_EXT_FAMILY -> {extended_family, up};
	    ?NET_EXT_FAMILY_SET -> {extended_family_set, down};
	    _ -> {Type, undefined}
	end,
    {ok, #{ 
	    hub_id => HubID,
	    type => network_command,
	    command_type => CommandType,
	    direction => Dir,
	    value => Value }}.

%% <<L=15,HUBID=0,
%%  4,60,1,56,0,0,0,0,16,0,0,0,16>>

%% @doc Decode error message
decode_error(HubID, <<CommandType:8, ErrorCode:8>>) ->
    {ok, #{
	   hub_id => HubID,
	   type => error,
	   command_type => CommandType,
	   error_code => ErrorCode,
	   error_name => get_error_name(ErrorCode)
	  }}.

%%%===================================================================
%%% Helper Functions
%%%===================================================================

get_property_name(?PROP_ADV_NAME) -> advertising_name;
get_property_name(?PROP_BUTTON) -> button;
get_property_name(?PROP_FW_VERSION) -> fw_version;
get_property_name(?PROP_HW_VERSION) -> hw_version;
get_property_name(?PROP_RSSI) -> rssi;
get_property_name(?PROP_BATTERY_VOLTAGE) -> battery_voltage;
get_property_name(?PROP_BATTERY_TYPE) -> battery_type;
get_property_name(_) -> unknown.

decode_operation(?OP_SET) -> set;
decode_operation(?OP_ENABLE_UPDATES) -> enable_updates;
decode_operation(?OP_DISABLE_UPDATES) -> disable_updates;
decode_operation(?OP_RESET) -> reset;
decode_operation(?OP_REQUEST_UPDATE) -> request_update;
decode_operation(?OP_UPDATE) -> update;
decode_operation(_) -> unknown.

decode_property_value(battery_voltage, <<Voltage:8>>) ->
    #{percent => Voltage};
decode_property_value(button, <<State:8>>) ->
    #{pressed => State =:= 1};
decode_property_value(rssi, <<RSSI:8/signed>>) ->
    #{rssi => RSSI};
decode_property_value(battery_type, <<Type:8>>) ->
    #{type => case Type of
        0 -> normal;
        1 -> rechargeable;
        _ -> unknown
    end};
decode_property_value(advertising_name, Name) ->
    #{name => Name};
decode_property_value(_, Value) ->
    Value.

%% Decode version number (32-bit signed integer)
decode_version(Version) ->
    Major = (Version bsr 28) band 16#07,
    Minor = (Version bsr 24) band 16#0F,
    BugFix = (Version bsr 16) band 16#FF,
    Build = Version band 16#FFFF,
    #{
        major => Major,
        minor => Minor,
        bugfix => BugFix,
        build => Build,
        string => io_lib:format("~B.~B.~B.~B", [Major, Minor, BugFix, Build])
    }.

%% Get I/O Type Name
get_io_type_name(16#0001) -> <<"Motor">>;
get_io_type_name(16#0002) -> <<"System Train Motor">>;
get_io_type_name(16#0005) -> <<"Button">>;
get_io_type_name(16#0008) -> <<"LED Light">>;
get_io_type_name(16#0014) -> <<"Voltage">>;
get_io_type_name(16#0015) -> <<"Current">>;
get_io_type_name(16#0016) -> <<"Piezo Tone">>;
get_io_type_name(16#0017) -> <<"RGB Light">>;
get_io_type_name(16#0022) -> <<"External Tilt Sensor">>;
get_io_type_name(16#0023) -> <<"Motion Sensor">>;
get_io_type_name(16#0025) -> <<"Vision Sensor">>;
get_io_type_name(16#0026) -> <<"External Motor with Tacho">>;
get_io_type_name(16#0027) -> <<"Internal Motor with Tacho">>;
get_io_type_name(16#0028) -> <<"Internal Tilt">>;
get_io_type_name(16#0037) -> <<"Remote Control Button">>;
get_io_type_name(16#0038) -> <<"Remote Control RSSI">>;
get_io_type_name(_) -> <<"Unknown Device">>.

get_error_name(16#01) -> ack;
get_error_name(16#02) -> mack;
get_error_name(16#03) -> buffer_overflow;
get_error_name(16#04) -> timeout;
get_error_name(16#05) -> command_not_recognized;
get_error_name(16#06) -> invalid_use;
get_error_name(16#07) -> overcurrent;
get_error_name(16#08) -> internal_error;
get_error_name(_) -> unknown.
