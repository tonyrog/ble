%%%-------------------------------------------------------------------
%%% @doc
%%% LEGO Wireless Protocol 3.0 BLE implementation
%%% Handles decoding/encoding of LEGO BLE advertising data and messages
%%% @end
%%%-------------------------------------------------------------------
-module(lego_ble).

%% API exports
-export([
	 decode/1,  %% ble_adv callback for manufacturer data
	 encode/1,  %% ble_adv callback for manufacturer

	 decode_adv_data/1,
	 decode_manufacturer_data/1,
	 encode_manufacturer_data/1,
	 decode_device_info/1,
	 get_system_type_name/1,
	 get_device_name/2,
	 decode_hub_capabilities/1,
	 decode_status/1,
	 is_lego_device/1
	]).

%% LEGO GATT Service UUIDs
-define(LEGO_HUB_SERVICE_UUID, <<"00001623-1212-efde-1623-785feabcd123">>).
-define(LEGO_HUB_CHARACTERISTIC_UUID, <<"00001624-1212-efde-1623-785feabcd123">>).
-define(LEGO_BOOTLOADER_SERVICE_UUID, <<"00001625-1212-efde-1623-785feabcd123">>).

-include("lego_messages.hrl").

%%%===================================================================
%%% API
%%%===================================================================

%% @doc Check if device is a LEGO device based on manufacturer data
is_lego_device(AdvData) when is_map(AdvData) ->
    case maps:get(manufacturer_data, AdvData, undefined) of
        undefined -> false;
        ManData -> is_lego_manufacturer_data(ManData)
    end;
is_lego_device(_) ->
    false.

is_lego_manufacturer_data(<<16#FF, ?LEGO_MANUFACTURER_ID:16/little, _/binary>>) ->
    true;
is_lego_manufacturer_data(_) ->
    false.

%% @doc Decode LEGO advertising data
%% Returns a map with decoded information

decode_adv_data(AdvData) when is_binary(AdvData) ->
    decode_adv_data(parse_adv_data(AdvData));
decode_adv_data(AdvData) when is_map(AdvData) ->
    Name = maps:get(local_name, AdvData, undefined),
    ManData = maps:get(manufacturer_data, AdvData, undefined),

    BaseInfo = #{
        name => Name,
        is_lego => is_lego_device(AdvData)
    },

    case ManData of
        undefined ->
            BaseInfo;
        _ ->
            case decode_manufacturer_data(ManData) of
                {ok, LegoInfo} ->
                    maps:merge(BaseInfo, LegoInfo);
                {error, _} ->
                    BaseInfo
            end
    end.

%% @doc Parse raw advertising data into structured format
parse_adv_data(Data) ->
    parse_adv_data(Data, #{}).

parse_adv_data(<<>>, Acc) ->
    Acc;
parse_adv_data(<<Len, Data/binary>>, Acc) when Len > 0 ->
    case Data of
        <<Payload:Len/binary, Rest/binary>> ->
            <<Type, Value/binary>> = Payload,
            NewAcc = parse_adv_type(Type, Value, Acc),
            parse_adv_data(Rest, NewAcc);
        _ ->
            Acc
    end;
parse_adv_data(_, Acc) ->
    Acc.

parse_adv_type(16#09, Name, Acc) -> % Complete Local Name
    Acc#{local_name => Name};
parse_adv_type(16#08, Name, Acc) -> % Shortened Local Name
    Acc#{local_name => Name};
parse_adv_type(16#FF, ManData, Acc) -> % Manufacturer Specific Data
    Acc#{manufacturer_data => <<16#FF, ManData/binary>>};
parse_adv_type(_, _, Acc) ->
    Acc.

%% @doc Decode LEGO manufacturer data
%% Format: Length(1) | Type(1) | ManufacturerID(2) | ButtonState(1) |
%%         SystemType(1) | Capabilities(1) | LastNetwork(1) | Status(1) | Option(1)
decode(Bin) when is_binary(Bin) ->
    try decode_manufacturer_data(Bin) of
	{ok, Flags} -> Flags
    catch
	error:_ -> Bin
    end.
	    
decode_manufacturer_data(<<16#FF, ?LEGO_MANUFACTURER_ID:16/little,
                          ButtonState:8, SystemType:8, Capabilities:8,
                          LastNetwork:8, Status:8, Option:8>>) ->
    {ok, #{
        manufacturer_id => ?LEGO_MANUFACTURER_ID,
        button_state => decode_button_state(ButtonState),
        system_type => decode_system_type(SystemType),
        device_number => decode_device_number(SystemType),
        device_name => get_device_name(decode_system_type(SystemType),
                                       decode_device_number(SystemType)),
        capabilities => decode_hub_capabilities(Capabilities),
        last_network_id => LastNetwork,
        status => decode_status(Status),
        option => Option
    }};
decode_manufacturer_data(<<16#FF, ?LEGO_MANUFACTURER_ID:16/little, _/binary>>) ->
    {error, incomplete_data};
decode_manufacturer_data(_) ->
    {error, not_lego_device}.

%% @doc Encode manufacturer data for advertising
encode(Flags) when is_map(Flags) ->
    try encode_manufacturer_data(Flags) of
	Bin -> Bin
    catch
	error:_ -> <<>>
    end.

encode_manufacturer_data(#{button_state := ButtonState,
			   system_type := SystemType,
			   device_number := DeviceNumber,
			   capabilities := Capabilities,
			   last_network_id := LastNetwork,
			   status := Status,
			   option := Option}) ->
    SystemTypeByte = encode_system_and_device(SystemType, DeviceNumber),
    CapabilitiesByte = encode_capabilities(Capabilities),
    StatusByte = encode_status(Status),

    <<16#09, 16#FF, ?LEGO_MANUFACTURER_ID:16/little,
      ButtonState:8, SystemTypeByte:8, CapabilitiesByte:8,
      LastNetwork:8, StatusByte:8, Option:8>>.

%% @doc Decode device information from connection
decode_device_info(Data) ->
    % TODO: Implement full message parsing based on Message Types
    {ok, #{raw_data => Data}}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

%% Decode button state
decode_button_state(0) -> not_pressed;
decode_button_state(1) -> pressed;
decode_button_state(_) -> unknown.

%% Decode system type (3 upper bits)
decode_system_type(Byte) ->
    case (Byte bsr 5) band 2#111 of
        2#000 -> wedo_2_0;
        2#001 -> duplo;
        2#010 -> system;
        2#011 -> system;
        _ -> unknown
    end.

%% Decode device number (5 lower bits)
decode_device_number(Byte) ->
    Byte band 2#11111.

%% Get device name from system type and device number
get_device_name(wedo_2_0, 0) -> <<"WeDo Hub">>;
get_device_name(duplo, 0) -> <<"Duplo Train">>;
get_device_name(system, 0) -> <<"Boost Hub">>;
get_device_name(system, 1) -> <<"2 Port Hub">>;
get_device_name(system, 2) -> <<"2 Port Handset">>;
get_device_name(_, _) -> <<"Unknown LEGO Device">>.

get_system_type_name(wedo_2_0) -> <<"LEGO WeDo 2.0">>;
get_system_type_name(duplo) -> <<"LEGO Duplo">>;
get_system_type_name(system) -> <<"LEGO System">>;
get_system_type_name(_) -> <<"Unknown">>.

%% Decode hub capabilities (bit field)
decode_hub_capabilities(Byte) ->
    #{
        central_role => (Byte band 2#00000001) =/= 0,
        peripheral_role => (Byte band 2#00000010) =/= 0,
        lpf2_devices => (Byte band 2#00000100) =/= 0,
        remote_controller => (Byte band 2#00001000) =/= 0
    }.

%% Encode capabilities to byte
encode_capabilities(#{central_role := Central,
                     peripheral_role := Peripheral,
                     lpf2_devices := LPF2,
                     remote_controller := RC}) ->
    (bool_to_bit(Central) bsl 0) bor
    (bool_to_bit(Peripheral) bsl 1) bor
    (bool_to_bit(LPF2) bsl 2) bor
    (bool_to_bit(RC) bsl 3).

bool_to_bit(true) -> 1;
bool_to_bit(false) -> 0.

%% Decode status flags
decode_status(Byte) ->
    #{
        can_be_peripheral => (Byte band 2#00000001) =/= 0,
        can_be_central => (Byte band 2#00000010) =/= 0,
        request_window => (Byte band 2#00100000) =/= 0,
        request_connect => (Byte band 2#01000000) =/= 0
    }.

%% Encode status to byte
encode_status(#{can_be_peripheral := Peripheral,
		can_be_central := Central,
		request_window := ReqWindow,
		request_connect := ReqConnect}) ->
    (bool_to_bit(Peripheral) bsl 0) bor
    (bool_to_bit(Central) bsl 1) bor
    (bool_to_bit(ReqWindow) bsl 5) bor
    (bool_to_bit(ReqConnect) bsl 6).

%% Encode system type and device number
encode_system_and_device(SystemType, DeviceNumber) ->
    SystemBits = case SystemType of
		     wedo_2_0 -> 2#000;
		     duplo -> 2#001;
		     system -> 2#010;
		     _ -> 2#000
		 end,
    (SystemBits bsl 5) bor (DeviceNumber band 2#11111).
