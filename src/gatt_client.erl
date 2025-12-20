%%% @author Tony Rogvall <tony@rogvall.se>
%%% @copyright (C) 2025, Tony Rogvall
%%% @doc
%%%    GATT Client for BLE Central Mode
%%%    Pure functional module - takes State, returns updated State
%%%
%%%    Functions send ATT requests via HCI and store pending request context in State.
%%%    When ATT responses arrive via ACL, handle_att_response/3 processes them.
%%% @end
%%% Created : 26 Nov 2025 by Tony Rogvall <tony@rogvall.se>

-module(gatt_client).

-export([
    send_discover_services_request/3,
    send_discover_characteristics_request/5,
    send_read_request/4,
    send_write_request/5,
    handle_att_response/3,
    handle_att_timeout/1,
    fail_pending_request/2
]).

%% ATT timeout and retry configuration
-define(ATT_TIMEOUT, 2000).      %% 2 seconds per attempt
-define(ATT_MAX_RETRIES, 2).     %% Max 2 retries

-include_lib("bt/include/hci.hrl").
-include_lib("../include/ble_log.hrl").

-include("ble_state.hrl").
-include("gatt_client.hrl").

%% ATT Protocol opcodes
-define(ATT_OP_ERROR_RSP,           16#01).
-define(ATT_OP_READ_BY_TYPE_REQ,    16#08).
-define(ATT_OP_READ_BY_TYPE_RSP,    16#09).
-define(ATT_OP_READ_REQ,            16#0A).
-define(ATT_OP_READ_RSP,            16#0B).
-define(ATT_OP_READ_BY_GROUP_REQ,   16#10).
-define(ATT_OP_READ_BY_GROUP_RSP,   16#11).
-define(ATT_OP_WRITE_REQ,           16#12).
-define(ATT_OP_WRITE_RSP,           16#13).
-define(ATT_OP_HANDLE_VALUE_NTF,    16#1B).

%% GATT UUIDs
-define(GATT_PRIM_SVC_UUID,         16#2800).
-define(GATT_CHARAC_UUID,           16#2803).

%% L2CAP CID for ATT
-define(L2CAP_ATT_CID, 16#0004).

%%====================================================================
%% API - Send ATT Requests
%%====================================================================

%% @doc Send discover primary services request
%% State must have pending_att = undefined (no pending request)
%% Returns: {ok, NewState} with pending_att set, or {error, Reason}
-spec send_discover_services_request(State::ble_state(), ConnHandle::integer(),
                                     From::pid()) ->
	  {ok, ble_state()} | {error, term()}.
send_discover_services_request(State, ConnHandle, From) ->
    send_discover_services_request(State, ConnHandle, From, 16#0001, 16#FFFF, []).

send_discover_services_request(State, ConnHandle, From, StartHandle, EndHandle, Acc) ->
    ?info("GATT: Discovering services (handles ~w-~w)",
	  [StartHandle, EndHandle]),

    AttPdu = <<?ATT_OP_READ_BY_GROUP_REQ,
               StartHandle:16/little,
               EndHandle:16/little,
               ?GATT_PRIM_SVC_UUID:16/little>>,

    Request = #att_request{
        type = discover_services,
        from = From,
        handle = StartHandle,
        conn_handle = ConnHandle,
        pdu = AttPdu,
        context = #{start_handle => StartHandle,
                    end_handle => EndHandle,
                    acc => Acc}
    },
    send_att_request(State, Request).

%% @doc Send discover characteristics request for a service
-spec send_discover_characteristics_request(State::ble_state(),
					    ConnHandle::handle(),
					    From::pid(),
					    ServHandle::handle(), Service::map()) ->
	  {ok, ble_state()} | {error, term()}.
send_discover_characteristics_request(State, ConnHandle, From, ServHandle, Service) ->
    send_discover_characteristics_request(State, ConnHandle, From, ServHandle, Service, []).

send_discover_characteristics_request(State, ConnHandle, From, ServHandle, Service, Acc) ->
    StartHandle = maps:get(handle, Service) + 1,
    EndHandle = maps:get(end_handle, Service),

    if StartHandle > EndHandle ->
            %% No characteristics possible in this service
            From ! {characteristics, lists:reverse(Acc)},
            {ok, State};
       true ->
            ?info("GATT: Discovering characteristics (handles ~w-~w)",
                  [StartHandle, EndHandle]),
            AttPdu = <<?ATT_OP_READ_BY_TYPE_REQ,
                       StartHandle:16/little,
                       EndHandle:16/little,
                       ?GATT_CHARAC_UUID:16/little>>,
            Request = #att_request{
                type = discover_characteristics,
                from = From,
                handle = ServHandle,
                conn_handle = ConnHandle,
                pdu = AttPdu,
                context = #{service => Service, acc => Acc}
            },
            send_att_request(State, Request)
    end.

%% @doc Send read characteristic value request
-spec send_read_request(State::ble_state(), ConnHandle::integer(),
                       From::pid(), Handle::integer()) ->
	  {ok, ble_state()} | {error, term()}.
send_read_request(State, ConnHandle, From, Handle) ->
    ?info("GATT: Reading handle ~w", [Handle]),
    AttPdu = <<?ATT_OP_READ_REQ, Handle:16/little>>,
    Request = #att_request{
        type = read,
        from = From,
        handle = Handle,
        conn_handle = ConnHandle,
        pdu = AttPdu
    },
    send_att_request(State, Request).

%% @doc Send write characteristic value request
-spec send_write_request(State::term(), ConnHandle::integer(),
                        From::pid(), Handle::integer(), Value::binary()) ->
    {ok, ble_state()} | {error, term()}.
send_write_request(State, ConnHandle, From, Handle, Value) ->
    ?info("GATT: Writing handle ~w", [Handle]),
    AttPdu = <<?ATT_OP_WRITE_REQ, Handle:16/little, Value/binary>>,
    Request = #att_request{
        type = write,
        from = From,
        handle = Handle,
        conn_handle = ConnHandle,
        pdu = AttPdu
    },
    send_att_request(State, Request).

%%====================================================================
%% API - Handle ATT Responses
%%====================================================================

%% @doc Handle incoming ATT response PDU
%% Matches it against pending_att in State, processes response, sends reply to From
%% Returns: NewState with pending_att = undefined
handle_att_response(AttPdu, ConnHandle, State) ->
    ?debug("GATT: Received ATT response: ~p (pending=~p)",
           [AttPdu, State#ble_state.pending_att =/= undefined]),
    case State#ble_state.pending_att of
        undefined ->
            %% No pending request - check if it's a notification
            case AttPdu of
                <<?ATT_OP_HANDLE_VALUE_NTF, Handle:16/little, Value/binary>> ->
                    handle_notification(ConnHandle, Handle, Value, State);
                _ ->
                    ?warning("GATT: Unexpected ATT response (no pending request): ~p",
                             [AttPdu]),
                    State
            end;
        #att_request{timer_ref = TRef} = Request ->
            erlang:cancel_timer(TRef),
            handle_att_response_with_request(AttPdu, ConnHandle, Request, State)
    end.

%%====================================================================
%% API - Handle ATT Timeout
%%====================================================================

%% @doc Handle ATT timeout - retry or fail
%% Returns: NewState
handle_att_timeout(State) ->
    case State#ble_state.pending_att of
        undefined ->
            State;
        #att_request{retries = Retries} = Request ->
            if Retries < ?ATT_MAX_RETRIES ->
                    ?warning("GATT: ATT timeout, retry ~w/~w",
                             [Retries + 1, ?ATT_MAX_RETRIES]),
                    State1 = State#ble_state{pending_att = undefined},
                    Request1 = Request#att_request{retries = Retries + 1},
                    {ok, State2} = send_att_request(State1, Request1),
                    State2;
               true ->
                    ?error("GATT: ATT timeout after ~w retries", [?ATT_MAX_RETRIES]),
                    fail_pending_request(Request, timeout),
                    State#ble_state{pending_att = undefined}
            end
    end.

%% @doc Send error to the waiting process
fail_pending_request(#att_request{from = From}, Reason) ->
    From ! {error, Reason};
fail_pending_request(_, _Reason) ->
    ok.

%%====================================================================
%% Internal - ATT Protocol
%%====================================================================

%% @doc Send ATT PDU over L2CAP/ACL
send_att_request(State, #att_request{conn_handle = ConnHandle, pdu = AttPdu} = Request) ->
    Hci = State#ble_state.hci,

    %% Build L2CAP packet: Length (2) + CID (2) + ATT PDU
    L2capLen = byte_size(AttPdu),
    L2capPdu = <<L2capLen:16/little, ?L2CAP_ATT_CID:16/little, AttPdu/binary>>,

    %% Build ACL packet: Handle+Flags (2) + Length (2) + L2CAP data
    AclHandle = ConnHandle band 16#0FFF,
    AclFlags = ?ACL_START_NO_FLUSH,
    AclHeader = <<?acl_handle_pack(AclHandle, AclFlags):16/little,
                  (byte_size(L2capPdu)):16/little>>,

    AclPacket = <<?HCI_ACLDATA_PKT, AclHeader/binary, L2capPdu/binary>>,

    case bt_hci:write(Hci, AclPacket) of
        {ok, _BytesWritten} ->
            TRef = erlang:start_timer(?ATT_TIMEOUT, self(), att_timeout),
            Request1 = Request#att_request{timer_ref = TRef},
            {ok, State#ble_state{pending_att = Request1}};
        {error, _} = Error ->
            ?error("GATT: Failed to send ATT PDU: ~p", [Error]),
            {ok, State}
    end.

%% @doc Handle ATT response based on request type
handle_att_response_with_request(AttPdu, ConnHandle, Request, State) ->
    #att_request{type = Type, from = From, handle = Handle, context = Ctx} = Request,

    case {Type, AttPdu} of
        %% Discover services response
        {discover_services, <<?ATT_OP_READ_BY_GROUP_RSP, Length, Data/binary>>} ->
            Services = parse_read_by_group_response(Length, Data),
            ?debug("Found ~w services", [length(Services)]),
            State1 = add_services(ConnHandle, Services, State),
            #{acc := Acc} = Ctx,

            case Services of
                [] ->
                    From ! {services, lists:reverse(Acc)},
                    State1#ble_state{pending_att = undefined};
                _ ->
                    LastService = lists:last(Services),
                    LastEndHandle = maps:get(end_handle, LastService),
                    NewAcc = lists:reverse(Services) ++ Acc,

                    if LastEndHandle >= 16#FFFF ->
                            From ! {services, lists:reverse(NewAcc)},
                            State1#ble_state{pending_att = undefined};
                       true ->
                            State2 = State1#ble_state{pending_att = undefined},
                            {ok, State3} = send_discover_services_request(
                                             State2, ConnHandle, From,
                                             LastEndHandle + 1, 16#FFFF, NewAcc),
                            State3
                    end
            end;

        %% Discover services - error (attribute not found = end of discovery)
        {discover_services, <<?ATT_OP_ERROR_RSP, ?ATT_OP_READ_BY_GROUP_REQ, _:16/little, 16#0A>>} ->
            #{acc := Acc} = Ctx,
            ?debug("  Discovery complete (~w services total)", [length(Acc)]),
            From ! {services, lists:reverse(Acc)},
            State#ble_state{pending_att = undefined};

        %% Discover characteristics response
        {discover_characteristics, <<?ATT_OP_READ_BY_TYPE_RSP, Length, Data/binary>>} ->
            Chars = parse_characteristic_response(Length, Data),
            ?debug("  Found ~w characteristics", [length(Chars)]),
            ServHandle = Handle,
            #{service := Service, acc := Acc} = Ctx,
            State1 = add_characteristics(ConnHandle, ServHandle, Chars, State),

            case Chars of
                [] ->
                    From ! {characteristics, lists:reverse(Acc)},
                    State1#ble_state{pending_att = undefined};
                _ ->
                    LastChar = lists:last(Chars),
                    LastHandle = maps:get(handle, LastChar),
                    ServiceEndHandle = maps:get(end_handle, Service),
                    NewAcc = lists:reverse(Chars) ++ Acc,

                    if LastHandle >= ServiceEndHandle ->
                            From ! {characteristics, lists:reverse(NewAcc)},
                            State1#ble_state{pending_att = undefined};
                       true ->
                            Service1 = Service#{handle => LastHandle},
                            State2 = State1#ble_state{pending_att = undefined},
                            {ok, State3} = send_discover_characteristics_request(
                                             State2, ConnHandle, From, ServHandle, Service1, NewAcc),
                            State3
                    end
            end;

        {discover_characteristics, <<?ATT_OP_ERROR_RSP, ?ATT_OP_READ_BY_TYPE_REQ, _:16/little, 16#0A>>} ->
            #{acc := Acc} = Ctx,
            ?debug("  Characteristic discovery complete (~w total)", [length(Acc)]),
            From ! {characteristics, lists:reverse(Acc)},
            State#ble_state{pending_att = undefined};

        %% Read characteristic response
        {read, <<?ATT_OP_READ_RSP, Value/binary>>} ->
            ?debug("  Read value: ~p", [Value]),
            From ! {value, Value},
            State#ble_state{pending_att = undefined};

        %% Write characteristic response
        {write, <<?ATT_OP_WRITE_RSP>>} ->
            ?debug("Write successful", []),
            From ! {ok, write_complete},
            State#ble_state{pending_att = undefined};

        %% ATT Error response
        {_, <<?ATT_OP_ERROR_RSP, _ReqOp, _Handle:16/little, ErrorCode>>} ->
            ?debug("ATT Error: 0x~2.16.0B", [ErrorCode]),
            From ! {error, {att_error, ErrorCode}},
            State#ble_state{pending_att = undefined};

        %% Notification received while waiting for response - handle it and keep waiting
        {_, <<?ATT_OP_HANDLE_VALUE_NTF, NtfHandle:16/little, Value/binary>>} ->
            State1 = handle_notification(ConnHandle, NtfHandle, Value, State),
            %% Re-arm the pending request (keep waiting for actual response)
            State1;

        %% Unknown/unexpected response
        _ ->
            ?warning("GATT: Unexpected ATT response for ~p: ~p", [Type, AttPdu]),
            State
    end.

%%====================================================================
%% Internal - Notification Handler
%%====================================================================

%% @doc Handle incoming notification
handle_notification(ConnHandle, AttrHandle, Value, State) ->
    ?info("GATT: Notification on handle ~w: ~p", [AttrHandle, Value]),
    Connections = State#ble_state.connections,
    case maps:get(ConnHandle, Connections, undefined) of
        undefined ->
            ?error("GATT: Notification for unknown connection ~w", [ConnHandle]),
            State;
        #connection{objects = Objects} = Conn ->
            Objects1 = update_characteristic_value(AttrHandle, Value, Objects),
	    ?debug("GATT: AttrHandle=~w, Objects1=~p\n", 
		   [AttrHandle,Objects1]),
            Conn1 = Conn#connection{objects = Objects1},
            case maps:get(AttrHandle, Objects, undefined) of
                #{uuid := UUID} ->
                    ble:call_subscribers(UUID, Value, remote,
                                         State#ble_state.subscribers);
                _ ->
                    ok
            end,
            Connections1 = Connections#{ConnHandle => Conn1},
            State#ble_state{connections = Connections1}
    end.

%% @doc Update characteristic value in service list
update_characteristic_value(AttrHandle, Value, Objects) ->
    case maps:get(AttrHandle, Objects, undefined) of
        undefined ->
            ?debug("update_characteristic_value: ~w, value=~p, no such handle",
                  [AttrHandle, Value]),
            Objects;
        Char ->
            case maps:get(value_handle, Char, undefined) of
                undefined -> Objects;
                AttrHandle ->
                    Char1 = Char#{value => Value},
                    Objects#{AttrHandle => Char1}
            end
    end.

%% @doc Add services to connection
add_services(ConnHandle, Services, State) ->
    Connections = State#ble_state.connections,
    case maps:get(ConnHandle, Connections, undefined) of
        undefined ->
            ?debug("add_service: no such handle"),
            State;
        #connection{objects = Objects, uuids = UUIDs} = Conn ->
            Objects1 = lists:foldl(
                fun(Service = #{handle := ServHandle}, Objs) ->
                    Objs#{ServHandle => Service}
                end, Objects, Services),
            UUIDs1 = lists:foldl(
                fun(#{uuid := UUID, handle := ServHandle}, UUs) ->
                    UUs#{UUID => ServHandle}
                end, UUIDs, Services),
            Conn1 = Conn#connection{objects = Objects1, uuids = UUIDs1},
            Connections1 = Connections#{ConnHandle => Conn1},
            State#ble_state{connections = Connections1}
    end.

%% @doc Add characteristics to connection
add_characteristics(ConnHandle, ServHandle, Chars, State) ->
    Connections = State#ble_state.connections,
    case maps:get(ConnHandle, Connections, undefined) of
        undefined ->
            ?debug("add_characteristics: no such handle"),
            State;
        #connection{objects = Objects, uuids = UUIDs} = Conn ->
            case maps:get(ServHandle, Objects, undefined) of
                undefined ->
                    ?debug("add_characteristics: service not found"),
                    State;
                Serv ->
                    ?debug("add_characteristics: ~p", [Chars]),
                    ValHandleList = [maps:get(value_handle, C) || C <- Chars],
                    Objects1 = lists:foldl(
                        fun(Char = #{value_handle := ValHandle}, Objs) ->
                            Objs#{ValHandle => Char}
                        end, Objects, Chars),
                    UUIDs1 = lists:foldl(
                        fun(#{uuid := UUID, value_handle := ValHandle}, UUs) ->
                            UUs#{UUID => ValHandle}
                        end, UUIDs, Chars),
                    ValHandleList1 = maps:get(characteristics, Serv, []) ++ ValHandleList,
                    Serv1 = Serv#{characteristics => ValHandleList1},
                    Objects2 = Objects1#{ServHandle => Serv1},
                    Conn1 = Conn#connection{objects = Objects2, uuids = UUIDs1},
                    Connections1 = Connections#{ConnHandle => Conn1},
                    State#ble_state{connections = Connections1}
            end
    end.

%%====================================================================
%% Internal - Response Parsers
%%====================================================================

%% @doc Parse Read By Group Type Response (for service discovery)
parse_read_by_group_response(Length, Data) ->
    parse_read_by_group_response(Length, Data, []).

parse_read_by_group_response(Length, Data, Acc) when byte_size(Data) >= Length ->
    case Data of
        <<Handle:16/little, EndHandle:16/little, Rest/binary>> ->
            UUIDLen = (Length - 4) * 8,
            <<UUID:UUIDLen/little, Remaining/binary>> = Rest,
            Service = #{
                handle => Handle,
                end_handle => EndHandle,
                uuid => ble:uuid(<<UUID:UUIDLen>>)
            },
            parse_read_by_group_response(Length, Remaining, [Service | Acc]);
        _ ->
            lists:reverse(Acc)
    end;
parse_read_by_group_response(_Length, _Data, Acc) ->
    lists:reverse(Acc).

%% @doc Parse Read By Type Response (for characteristic discovery)
parse_characteristic_response(Length, Data) ->
    parse_characteristic_response(Length, Data, []).

parse_characteristic_response(Length, Data, Acc) when byte_size(Data) >= Length ->
    case Data of
        <<Handle:16/little, Properties:8, ValueHandle:16/little, Rest/binary>> ->
            UUIDLen = (Length - 5) * 8,
            <<UUID:UUIDLen/little, Remaining/binary>> = Rest,
            Char = #{
                handle => Handle,
                properties => decode_properties(Properties),
                value_handle => ValueHandle,
                uuid => ble:uuid(<<UUID:UUIDLen>>)
            },
            parse_characteristic_response(Length, Remaining, [Char | Acc]);
        _ ->
            lists:reverse(Acc)
    end;
parse_characteristic_response(_Length, _Data, Acc) ->
    lists:reverse(Acc).

-define(PROP(Mask, Flag, Name),
    if (Mask) band (Flag) =:= (Flag) -> [Name]; true -> [] end).

%% @doc Decode characteristic properties byte
decode_properties(Byte) ->
    ?PROP(Byte, 16#01, broadcast) ++
    ?PROP(Byte, 16#02, read) ++
    ?PROP(Byte, 16#04, write_without_response) ++
    ?PROP(Byte, 16#08, write) ++
    ?PROP(Byte, 16#10, notify) ++
    ?PROP(Byte, 16#20, indicate) ++
    ?PROP(Byte, 16#40, authenticated_signed_writes) ++
    ?PROP(Byte, 16#80, extended_properties).
