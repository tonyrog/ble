%%% @doc
%%% BLE Heart rate client/subscriber
%%%
-module(ble_heart_client).

-export([connect_to_heart_rate/1]).

%% Example: Connect to a heart rate monitor
connect_to_heart_rate(DeviceAddr) ->
    io:format("~n"),
    io:format("Connecting to Heart Rate Monitor...~n"),
    io:format("Address: ~p~n", [DeviceAddr]),
    io:format("~n"),

    %% Initialize BLE Central
    {ok, BLE} = ble:begin_central(),

    %% Connect to device
    case ble:connect(BLE, DeviceAddr) of
        {ok, Connection} ->
            io:format("Connected!~n"),
            io:format("~n"),

            %% Subscribe to heart rate notifications
            Callback = fun(UUID, Value) ->
                <<_Flags, HeartRate>> = Value,
                io:format("♥ Heart Rate: ~w bpm (UUID: ~p)~n", [HeartRate, UUID])
            end,

            ble:subscribe(BLE, "2A37", Callback),  % Heart Rate Measurement

            io:format("Subscribed to heart rate notifications~n"),
            io:format("Receiving heart rate data...~n"),
            io:format("(Press Ctrl+C to stop)~n"),
            io:format("~n"),

            %% Keep running
            {ok, BLE, Connection};

        Error ->
            io:format("Connection failed: ~p~n", [Error]),
            ble:stop(BLE),
            Error
    end.
