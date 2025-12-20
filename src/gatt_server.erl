%%% @author Tony Rogvall <tony@rogvall.se>
%%% @copyright (C) 2025, Tony Rogvall
%%% @doc
%%%    GATT Server for BLE Peripheral
%%%    Handles ATT (Attribute Protocol) over L2CAP channel 0x0004
%%% @end

-module(gatt_server).

-export([start/4, stop/1]).
-export([notify/3, update_value/3]).
-export([handle_att_request/3]).  % Called from ble module

-include_lib("bt/include/hci.hrl").
-include("../include/ble_log.hrl").

%% ATT Protocol opcodes
-define(ATT_OP_ERROR_RSP,           16#01).
-define(ATT_OP_MTU_REQ,             16#02).
-define(ATT_OP_MTU_RSP,             16#03).
-define(ATT_OP_FIND_INFO_REQ,       16#04).
-define(ATT_OP_FIND_INFO_RSP,       16#05).
-define(ATT_OP_FIND_BY_TYPE_REQ,    16#06).
-define(ATT_OP_FIND_BY_TYPE_RSP,    16#07).
-define(ATT_OP_READ_BY_TYPE_REQ,    16#08).
-define(ATT_OP_READ_BY_TYPE_RSP,    16#09).
-define(ATT_OP_READ_REQ,            16#0A).
-define(ATT_OP_READ_RSP,            16#0B).
-define(ATT_OP_READ_BLOB_REQ,       16#0C).
-define(ATT_OP_READ_BLOB_RSP,       16#0D).
-define(ATT_OP_READ_MULTI_REQ,      16#0E).
-define(ATT_OP_READ_MULTI_RSP,      16#0F).
-define(ATT_OP_READ_BY_GROUP_REQ,   16#10).
-define(ATT_OP_READ_BY_GROUP_RSP,   16#11).
-define(ATT_OP_WRITE_REQ,           16#12).
-define(ATT_OP_WRITE_RSP,           16#13).
-define(ATT_OP_WRITE_CMD,           16#52).
-define(ATT_OP_HANDLE_VALUE_NTF,    16#1B).
-define(ATT_OP_HANDLE_VALUE_IND,    16#1D).
-define(ATT_OP_HANDLE_VALUE_CFM,    16#1E).

%% ATT Error codes
-define(ATT_ECODE_INVALID_HANDLE,   16#01).
-define(ATT_ECODE_READ_NOT_PERM,    16#02).
-define(ATT_ECODE_WRITE_NOT_PERM,   16#03).
-define(ATT_ECODE_INVALID_PDU,      16#04).
-define(ATT_ECODE_INSUFF_AUTHEN,    16#05).
-define(ATT_ECODE_REQ_NOT_SUPP,     16#06).
-define(ATT_ECODE_INVALID_OFFSET,   16#07).
-define(ATT_ECODE_INSUFF_AUTHOR,    16#08).
-define(ATT_ECODE_PREP_QUEUE_FULL,  16#09).
-define(ATT_ECODE_ATTR_NOT_FOUND,   16#0A).
-define(ATT_ECODE_ATTR_NOT_LONG,    16#0B).
-define(ATT_ECODE_INSUFF_ENC_KEY,   16#0C).
-define(ATT_ECODE_INVAL_ATTR_LEN,   16#0D).
-define(ATT_ECODE_UNLIKELY,         16#0E).
-define(ATT_ECODE_INSUFF_ENC,       16#0F).
-define(ATT_ECODE_UNSUPP_GRP_TYPE,  16#10).
-define(ATT_ECODE_INSUFF_RESOURCES, 16#11).

-define(L2CAP_ATT_CID, 16#0004).  % Fixed channel for ATT

%% GATT UUIDs
-define(GATT_PRIM_SVC_UUID,         <<16#2800:16/little>>).
-define(GATT_CHAR_UUID,             <<16#2803:16/little>>).
-define(GATT_CLIENT_CHAR_CFG_UUID,  <<16#2902:16/little>>).  % CCCD

-record(gatt_state, {
    hci :: reference(),
    conn_handle :: integer(),
    services :: list(),
    mtu = 23 :: integer(),
    attributes = [] :: list(),  % [#{handle, type, value, props, uuid}]
    uuid_to_handle = #{} :: map(),  % UUID => Handle mapping
    ble_pid :: pid() | undefined  % BLE process to notify on writes
}).

%%====================================================================
%% API
%%====================================================================

%% @doc Start GATT server for a connection
-spec start(Hci::reference(), ConnHandle::integer(), Services::list(), BlePid::pid()) ->
    {ok, pid()} | {error, term()}.
start(Hci, ConnHandle, Services, BlePid) ->
    {Attrs, UUIDMap} = build_attribute_table(Services),
    State = #gatt_state{
        hci = Hci,
        conn_handle = ConnHandle,
        services = Services,
        attributes = Attrs,
        uuid_to_handle = UUIDMap,
        ble_pid = BlePid
    },
    ?info("GATT Server: Built ~w attributes", [length(Attrs)]),
    lists:foreach(fun(A) ->
                          ?debug("  Handle ~w: Type=~p, Value=~p",
                                 [maps:get(handle, A),
                                  maps:get(type, A),
                                  maps:get(value, A)])
                  end, Attrs),
    Pid = spawn_link(fun() -> gatt_loop(State) end),
    {ok, Pid}.

%% @doc Stop GATT server
-spec stop(Pid::pid()) -> ok.
stop(Pid) ->
    Pid ! stop,
    ok.

%% @doc Send notification to client
-spec notify(Pid::pid(), UUID::binary(), Value::binary()) -> ok.
notify(Pid, UUID, Value) ->
    Pid ! {notify, UUID, Value},
    ok.

%% @doc Update characteristic value
-spec update_value(Pid::pid(), UUID::binary(), Value::binary()) -> ok.
update_value(Pid, UUID, Value) ->
    Pid ! {update_value, UUID, Value},
    ok.

%% @doc Handle ATT request from ble module
-spec handle_att_request(Pid::pid(), AttPdu::binary(), ConnHandle::integer()) -> ok.
handle_att_request(Pid, AttPdu, ConnHandle) ->
    Pid ! {att_request, AttPdu, ConnHandle},
    ok.

%%====================================================================
%% Internal - Attribute Table
%%====================================================================

%% @doc Build ATT attribute table from GATT services
build_attribute_table(Services) ->
    {Attrs, UUIDMap, _NextHandle} = lists:foldl(
        fun(Service, {AccAttrs, AccUUID, Handle}) ->
            add_service_attributes(Service, AccAttrs, AccUUID, Handle)
        end,
        {[], #{}, 16#0001},  % Start at handle 1
        Services
    ),
    {lists:reverse(Attrs), UUIDMap}.

%% @doc Add attributes for a service
add_service_attributes(Service, Attrs, UUIDMap, Handle) ->
    UUID = maps:get(uuid, Service),
    Characteristics = maps:get(characteristics, Service, []),
    %% Service Declaration attribute
    ServiceAttr = #{
        handle => Handle,
        type => ?GATT_PRIM_SVC_UUID,
	value => bt_util:uuid_to_little(UUID),
        props => [read],
        uuid => UUID  % For easy lookup
    },

    %% Add characteristics
    {CharAttrs, CharUUIDMap, NextHandle} = lists:foldl(
        fun(Char, {AccC, AccU, H}) ->
            add_characteristic_attributes(Char, AccC, AccU, H)
        end,
        {[ServiceAttr | Attrs], UUIDMap, Handle + 1},
        Characteristics
    ),

    {CharAttrs, CharUUIDMap, NextHandle}.

%% @doc Add attributes for a characteristic
add_characteristic_attributes(Char, Attrs, UUIDMap, Handle) ->
    UUID = maps:get(uuid, Char),
    Props = maps:get(properties, Char, [read]),
    Value = maps:get(value, Char, <<>>),

    %% Characteristic Declaration (handle H)
    PropsByte = encode_properties(Props),
    ValueHandle = Handle + 1,
    UUIDLittle = bt_util:uuid_to_little(UUID),
    CharDecl = #{
        handle => Handle,
        type => ?GATT_CHAR_UUID,
        value => <<PropsByte, ValueHandle:16/little, UUIDLittle/binary>>,
        props => [read],
        uuid => ?GATT_CHAR_UUID
    },

    %% Characteristic Value (handle H+1)
    CharValue = #{
        handle => ValueHandle,
        type => UUID,
        value => Value,
        props => Props,
        uuid => UUID
    },

    %% Add UUID to handle mapping
    NewUUIDMap = maps:put(UUID, ValueHandle, UUIDMap),

    %% If notify/indicate, add Client Characteristic Configuration Descriptor (CCCD)
    HasNotify = lists:member(notify, Props) orelse lists:member(indicate, Props),
    if HasNotify ->
            CCCD = #{
                handle => ValueHandle + 1,
                type => ?GATT_CLIENT_CHAR_CFG_UUID,
                value => <<0,0>>,  % Notifications disabled by default
                props => [read, write],
                uuid => ?GATT_CLIENT_CHAR_CFG_UUID
            },
            {[CCCD, CharValue, CharDecl | Attrs], NewUUIDMap, ValueHandle + 2};
       true ->
            {[CharValue, CharDecl | Attrs], NewUUIDMap, ValueHandle + 1}
    end.

%% @doc Encode characteristic properties byte
encode_properties(Props) ->
    lists:foldl(
        fun(broadcast, Acc) -> Acc bor 16#01;
           (read, Acc) -> Acc bor 16#02;
           (write_without_response, Acc) -> Acc bor 16#04;
           (write, Acc) -> Acc bor 16#08;
           (notify, Acc) -> Acc bor 16#10;
           (indicate, Acc) -> Acc bor 16#20;
           (auth_signed_writes, Acc) -> Acc bor 16#40;
           (extended_props, Acc) -> Acc bor 16#80;
           (_, Acc) -> Acc
        end,
        0,
        Props
    ).

%%====================================================================
%% Internal - GATT Server Loop
%%====================================================================

gatt_loop(State) ->
    receive
        {att_request, AttPdu, ConnHandle} ->
            NewState = process_att_request(AttPdu, ConnHandle, State),
            gatt_loop(NewState);

        {notify, UUID, Value} ->
            send_notification_by_uuid(UUID, Value, State),
            gatt_loop(State);

        {update_value, UUID, NewValue} ->
            NewState = update_attribute_value(UUID, NewValue, State),
            gatt_loop(NewState);

        stop ->
            ?info("GATT Server stopped"),
            ok;

        Other ->
            ?warning("GATT Server: Unknown message: ~p", [Other]),
            gatt_loop(State)
    end.

%%====================================================================
%% Internal - ATT Request Handling
%%====================================================================

process_att_request(<<?ATT_OP_MTU_REQ, ClientMTU:16/little>>, ConnHandle, State) ->
    ?debug("GATT: MTU Exchange Request, client MTU=~w", [ClientMTU]),
    ServerMTU = State#gatt_state.mtu,
    MTU = min(ClientMTU, ServerMTU),
    Response = <<?ATT_OP_MTU_RSP, MTU:16/little>>,
    send_att_pdu(Response, ConnHandle, State),
    State#gatt_state{mtu = MTU};

process_att_request(<<?ATT_OP_READ_BY_GROUP_REQ, StartHandle:16/little,
                       EndHandle:16/little, GroupType/binary>>, ConnHandle, State) ->
    ?debug("GATT: Read By Group Type Request ~w-~w, type=~p",
           [StartHandle, EndHandle, GroupType]),
    Attrs = find_attributes_by_type(GroupType, StartHandle, EndHandle,
                                   State#gatt_state.attributes),
    Response = format_read_by_group_response(Attrs, GroupType),
    send_att_pdu(Response, ConnHandle, State),
    State;

process_att_request(<<?ATT_OP_READ_BY_TYPE_REQ, StartHandle:16/little,
                       EndHandle:16/little, AttrType/binary>>, ConnHandle, State) ->
    ?debug("GATT: Read By Type Request ~w-~w, type=~p",
           [StartHandle, EndHandle, AttrType]),
    Attrs = find_attributes_by_type(AttrType, StartHandle, EndHandle,
                                   State#gatt_state.attributes),
    Response = format_read_by_type_response(Attrs),
    send_att_pdu(Response, ConnHandle, State),
    State;

process_att_request(<<?ATT_OP_READ_REQ, Handle:16/little>>, ConnHandle, State) ->
    ?debug("GATT: Read Request, handle=~w", [Handle]),
    case find_attribute_by_handle(Handle, State#gatt_state.attributes) of
        {ok, Attr} ->
            Value = maps:get(value, Attr),
            Response = <<?ATT_OP_READ_RSP, Value/binary>>,
            send_att_pdu(Response, ConnHandle, State);
        error ->
            Error = <<?ATT_OP_ERROR_RSP, ?ATT_OP_READ_REQ,
                     Handle:16/little, ?ATT_ECODE_INVALID_HANDLE>>,
            send_att_pdu(Error, ConnHandle, State)
    end,
    State;

process_att_request(<<?ATT_OP_WRITE_REQ, Handle:16/little, NewValue/binary>>,
                    ConnHandle, State) ->
    ?debug("GATT: Write Request, handle=~w, value=~p", [Handle, NewValue]),
    case find_attribute_by_handle(Handle, State#gatt_state.attributes) of
        {ok, Attr} ->
            Props = maps:get(props, Attr, []),
            case lists:member(write, Props) of
                true ->
                    %% Update the value
                    NewAttrs = update_attribute_value_by_handle(Handle, NewValue,
                                                               State#gatt_state.attributes),
                    %% Notify BLE process about the write
                    UUID = maps:get(uuid, Attr, undefined),
                    notify_ble_process(UUID, NewValue, State),
                    Response = <<?ATT_OP_WRITE_RSP>>,
                    send_att_pdu(Response, ConnHandle, State),
                    State#gatt_state{attributes = NewAttrs};
                false ->
                    Error = <<?ATT_OP_ERROR_RSP, ?ATT_OP_WRITE_REQ,
                             Handle:16/little, ?ATT_ECODE_WRITE_NOT_PERM>>,
                    send_att_pdu(Error, ConnHandle, State),
                    State
            end;
        error ->
            Error = <<?ATT_OP_ERROR_RSP, ?ATT_OP_WRITE_REQ,
                     Handle:16/little, ?ATT_ECODE_INVALID_HANDLE>>,
            send_att_pdu(Error, ConnHandle, State),
            State
    end;

process_att_request(<<?ATT_OP_WRITE_CMD, Handle:16/little, NewValue/binary>>,
                    _ConnHandle, State) ->
    ?debug("GATT: Write Command, handle=~w, value=~p", [Handle, NewValue]),
    %% Write command has no response
    NewAttrs = update_attribute_value_by_handle(Handle, NewValue,
                                               State#gatt_state.attributes),
    %% Notify BLE process about the write
    case find_attribute_by_handle(Handle, State#gatt_state.attributes) of
        {ok, Attr} ->
            UUID = maps:get(uuid, Attr, undefined),
            notify_ble_process(UUID, NewValue, State);
        error ->
            ok
    end,
    State#gatt_state{attributes = NewAttrs};

%% Handle Value Indication from client - send confirmation back
process_att_request(<<?ATT_OP_HANDLE_VALUE_IND, Handle:16/little, _Value/binary>>,
                    ConnHandle, State) ->
    ?debug("GATT: Received Handle Value Indication, handle=~w", [Handle]),
    %% Send confirmation (no payload)
    Response = <<?ATT_OP_HANDLE_VALUE_CFM>>,
    send_att_pdu(Response, ConnHandle, State),
    State;

%% Handle Value Confirmation from client - response to our indication
process_att_request(<<?ATT_OP_HANDLE_VALUE_CFM>>, _ConnHandle, State) ->
    ?debug("GATT: Received Handle Value Confirmation"),
    %% No response needed - this confirms client received our indication
    State;

process_att_request(<<Opcode, _/binary>>, ConnHandle, State) ->
    ?warning("GATT: Unsupported ATT opcode: 0x~2.16.0B", [Opcode]),
    Error = <<?ATT_OP_ERROR_RSP, Opcode, 0:16/little, ?ATT_ECODE_REQ_NOT_SUPP>>,
    send_att_pdu(Error, ConnHandle, State),
    State.

%%====================================================================
%% Internal - Response Formatting
%%====================================================================

format_read_by_group_response([], _GroupType) ->
    <<?ATT_OP_ERROR_RSP, ?ATT_OP_READ_BY_GROUP_REQ, 0:16/little,
      ?ATT_ECODE_ATTR_NOT_FOUND>>;
format_read_by_group_response(Attrs, _GroupType) ->
    %% Format: opcode(1) + length(1) + data
    %% Data: handle(2) + end_handle(2) + value(variable)
    %% All entries must have same length
    case Attrs of
        [FirstAttr | _] ->
            FirstValue = maps:get(value, FirstAttr),
            ValueLen = byte_size(FirstValue),
            EntryLen = 4 + ValueLen,  % handle(2) + end_handle(2) + value

            %% Build response data
            Data = lists:foldl(
                fun(Attr, Acc) ->
                    Handle = maps:get(handle, Attr),
                    Value = maps:get(value, Attr),
                    %% End handle is the handle of this service
                    %% (simplified - should be last handle of service)
                    EndHandle = Handle + 10,  % Approximation
                    <<Acc/binary, Handle:16/little, EndHandle:16/little, Value/binary>>
                end,
                <<>>,
                Attrs
            ),
            <<?ATT_OP_READ_BY_GROUP_RSP, EntryLen, Data/binary>>;
        [] ->
            <<?ATT_OP_ERROR_RSP, ?ATT_OP_READ_BY_GROUP_REQ, 0:16/little,
              ?ATT_ECODE_ATTR_NOT_FOUND>>
    end.

format_read_by_type_response([]) ->
    <<?ATT_OP_ERROR_RSP, ?ATT_OP_READ_BY_TYPE_REQ, 0:16/little,
      ?ATT_ECODE_ATTR_NOT_FOUND>>;
format_read_by_type_response(Attrs) ->
    %% Format: opcode(1) + length(1) + data
    %% Data: handle(2) + value(variable)
    case Attrs of
        [FirstAttr | _] ->
            FirstValue = maps:get(value, FirstAttr),
            ValueLen = byte_size(FirstValue),
            EntryLen = 2 + ValueLen,  % handle(2) + value

            Data = lists:foldl(
                fun(Attr, Acc) ->
                    Handle = maps:get(handle, Attr),
                    Value = maps:get(value, Attr),
                    <<Acc/binary, Handle:16/little, Value/binary>>
                end,
                <<>>,
                Attrs
            ),
            <<?ATT_OP_READ_BY_TYPE_RSP, EntryLen, Data/binary>>;
        [] ->
            <<?ATT_OP_ERROR_RSP, ?ATT_OP_READ_BY_TYPE_REQ, 0:16/little,
              ?ATT_ECODE_ATTR_NOT_FOUND>>
    end.

%%====================================================================
%% Internal - Sending
%%====================================================================

send_att_pdu(Pdu, ConnHandle, State) ->
    ?debug("GATT: Sending ATT PDU on handle ~w: ~p", [ConnHandle, Pdu]),
    send_l2cap_packet(State#gatt_state.hci, ConnHandle, ?L2CAP_ATT_CID, Pdu).

send_notification_by_uuid(UUID, Value, State) ->
    case maps:get(UUID, State#gatt_state.uuid_to_handle, undefined) of
        undefined ->
            ?warning("GATT: Cannot send notification - UUID ~p not found", [UUID]),
            ok;
        Handle ->
            send_notification(Handle, Value, State)
    end.

send_notification(Handle, Value, State) ->
    Pdu = <<?ATT_OP_HANDLE_VALUE_NTF, Handle:16/little, Value/binary>>,
    ?debug("GATT: Sending notification on handle ~w", [Handle]),
    send_l2cap_packet(State#gatt_state.hci, State#gatt_state.conn_handle,
                     ?L2CAP_ATT_CID, Pdu).

%% @doc Send L2CAP packet over ACL
send_l2cap_packet(Hci, ConnHandle, CID, Payload) ->
    %% L2CAP header: Length (2) + CID (2)
    L2capLen = byte_size(Payload),
    L2capHeader = <<L2capLen:16/little, CID:16/little>>,

    %% ACL header: Handle (12 bits) + PB flags (2) + BC flags (2) + Length (2)
    PB = 2#00,  %% First non-automatically-flushable packet
    BC = 2#00,  %% Point-to-point
    Handle = ConnHandle bor (PB bsl 12) bor (BC bsl 14),
    ACLLen = byte_size(L2capHeader) + byte_size(Payload),

    ACLPacket = <<?HCI_ACLDATA_PKT:8, Handle:16/native, ACLLen:16/little,
                  L2capHeader/binary, Payload/binary>>,

    bt_hci:write(Hci, ACLPacket).

%%====================================================================
%% Internal - Attribute Operations
%%====================================================================

find_attribute_by_handle(Handle, Attrs) ->
    case [A || A <- Attrs, maps:get(handle, A) =:= Handle] of
        [Attr | _] -> {ok, Attr};
        [] -> error
    end.

find_attributes_by_type(Type, Start, End, Attrs) ->
    [A || A <- Attrs,
          maps:get(type, A) =:= Type,
          maps:get(handle, A) >= Start,
          maps:get(handle, A) =< End].

update_attribute_value(UUID, NewValue, State) ->
    NewAttrs = lists:map(
        fun(Attr) ->
            case maps:get(uuid, Attr, undefined) of
                UUID -> Attr#{value => NewValue};
                _ -> Attr
            end
        end,
        State#gatt_state.attributes
    ),
    State#gatt_state{attributes = NewAttrs}.

update_attribute_value_by_handle(Handle, NewValue, Attrs) ->
    lists:map(
        fun(Attr) ->
            case maps:get(handle, Attr) of
                Handle -> Attr#{value => NewValue};
                _ -> Attr
            end
        end,
        Attrs
    ).

%% @doc Notify BLE process about remote write
notify_ble_process(UUID, Value, State) ->
    case State#gatt_state.ble_pid of
        undefined ->
            ok;
        BlePid when is_pid(BlePid) ->
            BlePid ! {remote_write, UUID, Value},
            ok
    end.
