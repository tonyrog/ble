%%%-------------------------------------------------------------------
%%% @doc
%%% Example usage of LEGO BLE modules
%%% @end
%%%-------------------------------------------------------------------
-module(lego_example).

-export([
    test_decode_adv/0,
    test_manufacturer_data/0,
    test_messages/0,
    scan_for_lego_devices/0
]).

%% @doc Test decoding advertising data
test_decode_adv() ->
    %% Example LEGO Boost Hub advertising data
    %% Format: Length | Type | Data
    AdvData = <<
        % Complete Local Name
        9, 16#09, "LegoHub",
        % Manufacturer Data
        9, 16#FF,
        16#97, 16#03,  % LEGO Manufacturer ID (0x0397 little-endian)
        0,              % Button State (not pressed)
        16#40,          % System Type (010) = LEGO System, Device (00000) = Boost Hub
        16#06,          % Capabilities: Peripheral + LPF2 devices
        0,              % Last Network ID
        16#01,          % Status: Can be peripheral
        0               % Option
    >>,

    io:format("~n=== Testing Advertising Data Decoder ===~n"),
    Result = lego_ble:decode_adv_data(AdvData),
    io:format("Decoded: ~p~n", [Result]),
    Result.

%% @doc Test manufacturer data encoding/decoding
test_manufacturer_data() ->
    io:format("~n=== Testing Manufacturer Data ===~n"),

    %% Create manufacturer data
    ManData = lego_ble:encode_manufacturer_data(#{
        button_state => 0,
        system_type => system,
        device_number => 0,
        capabilities => #{
            central_role => false,
            peripheral_role => true,
            lpf2_devices => true,
            remote_controller => false
        },
        last_network_id => 0,
        status => #{
            can_be_peripheral => true,
            can_be_central => false,
            request_window => false,
            request_connect => false
        },
        option => 0
    }),

    io:format("Encoded manufacturer data: ~p~n", [ManData]),

    %% Decode it back
    {ok, Decoded} = lego_ble:decode_manufacturer_data(ManData),
    io:format("Decoded: ~p~n", [Decoded]),
    Decoded.

%% @doc Test message encoding/decoding
test_messages() ->
    io:format("~n=== Testing Message Encoding/Decoding ===~n"),

    %% Test battery voltage request
    BatteryReq = lego_messages:encode_hub_property_request(16#06, 16#05),
    io:format("Battery request: ~w~n", [BatteryReq]),

    %% Test Hub Attached I/O message (motor attached to port 0)
    AttachedMsg = <<
        15,             % Length
        0,              % Hub ID
        16#04,          % Message Type: Hub Attached I/O
        0,              % Port ID
        1,              % Event: Attached
        16#27, 16#00,   % I/O Type ID: Internal Motor with Tacho (0x0027)
        0, 0, 0, 0,     % HW Revision
        0, 0, 0, 0      % SW Revision
    >>,

    case lego_messages:decode_message(AttachedMsg) of
        {ok, Decoded} ->
            io:format("Decoded attached I/O: ~p~n", [Decoded]);
        {error, Reason} ->
            io:format("Error decoding: ~p~n", [Reason])
    end.

%% @doc Scan for LEGO devices
%% This is a conceptual example - actual scanning depends on your BLE stack
scan_for_lego_devices() ->
    io:format("~n=== Scanning for LEGO Devices ===~n"),
    io:format("Looking for devices with Manufacturer ID 0x0397...~n"),

    %% Example: Check if advertising data is from LEGO
    ExampleAdvData = #{
        local_name => <<"MyHub">>,
        manufacturer_data => <<16#FF, 16#97, 16#03, 0, 16#40, 16#06, 0, 1, 0>>
    },

    case lego_ble:is_lego_device(ExampleAdvData) of
        true ->
            io:format("Found LEGO device!~n"),
            DecodedInfo = lego_ble:decode_adv_data(ExampleAdvData),
            io:format("Device info: ~p~n", [DecodedInfo]);
        false ->
            io:format("Not a LEGO device~n")
    end.
