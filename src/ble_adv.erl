%%% @author Tony Rogvall <tony@rogvall.se>
%%% @copyright (C) 2025, Tony Rogvall
%%% @doc
%%%    BLE advertising 
%%% @end
%%% Created : 25 Nov 2025 by Tony Rogvall <tony@rogvall.se>

-module(ble_adv).

-export([decode/1, decode/2]).
-export([get_name/1]).

-include_lib("bt/include/bt.hrl").
-include("ble_adv.hrl").

-define(FLAG(Flag, Mask, Name),
	if (((Flag) band (Mask)) =:= (Flag)) -> [Name]; true -> [] end).

%% @doc Parse advertising data to extract device name
%% AD Structure format: Length(1) + Type(1) + Data(Length-1)
decode(Data) ->
    decode(Data, undefined).

decode(Data, Decoder) when is_atom(Decoder) ->
    decode_(Data, Decoder, [{raw,Data}]).

decode_(<<>>, _Decoder, Acc) ->
    Acc;
decode_(<<0, _/binary>>, _Decoder, Acc) ->
    %% Zero length means end of data
    Acc;
decode_(<<Length:8, Rest/binary>>, Decoder, Acc)
  when byte_size(Rest) >= Length ->
    <<AdData:Length/binary, NextRest/binary>> = Rest,
    <<Type,FieldData/binary>> = AdData,
    if Type == ?DATA_TYPE_MANUFACTURER_DATA ->
	    try apply(Decoder, decode, [AdData]) of
		Flags ->
		    decode_(NextRest, Decoder, [{manufacturer,Flags}|Acc])
	    catch 
		error:_ ->
		    decode_(NextRest, Decoder, [{manufacturer,FieldData}|Acc])
	    end;
       true ->
	    Field = decode_field(Type, FieldData),
	    decode_(NextRest, Decoder, [Field|Acc])
    end;
decode_(_, _Decoder, Acc) ->
    %% Incomplete data
    Acc.

decode_field(?DATA_TYPE_FLAGS, <<Flags>>) ->
    FlagList =
	?FLAG(?FLAG_LE_LIMITED_DISC_MODE, Flags, le_limited_disc_mode) ++
	?FLAG(?FLAG_LE_GENERAL_DISC_MODE, Flags, le_general_disc_mode) ++
	?FLAG(?FLAG_BR_EDR_NOT_SUPPORTED, Flags, br_edr_not_supported) ++
	?FLAG(?FLAG_LE_BR_EDR_CONTROLLER, Flags, le_br_edr_controller) ++
	?FLAG(?FLAG_LE_BR_EDR_HOST, Flags, le_br_edr_host),
    {flags, FlagList};
decode_field(?DATA_TYPE_SHORT_NAME, ShortName) ->
    {short_name, utf8_name(ShortName)};
decode_field(?DATA_TYPE_INCOMP_16BITS_UUIDS, Data) ->
    {uuids, [?BT_UUID16(N) || <<N:16/little>> <= Data]};
decode_field(?DATA_TYPE_COMP_16BITS_UUIDS, Data) ->
    {uuids, [?BT_UUID16(N) || <<N:16/little>> <= Data]};
decode_field(?DATA_TYPE_INCOMP_32BITS_UUIDS, Data) ->
    {uuids, [?BT_UUID32(N) || <<N:32/little>> <= Data]};    
decode_field(?DATA_TYPE_COMP_32BITS_UUIDS, Data) ->
    {uuids, [?BT_UUID32(N) || <<N:32/little>> <= Data]};
decode_field(?DATA_TYPE_INCOMP_128BITS_UUIDS, Data) ->
    {uuids, [<<N:128>> || <<N:128/little>> <= Data]};
decode_field(?DATA_TYPE_COMP_128BITS_UUIDS, Data) ->
    {uuids, [<<N:128>> || <<N:128/little>> <= Data]};
decode_field(?DATA_TYPE_COMPLETE_NAME, CompleteLocalName) ->
    {name, utf8_name(CompleteLocalName)};
decode_field(?DATA_TYPE_TX_POWER_LEVEL, <<Level>>) ->
    {tx_power_level, Level};
decode_field(?DATA_TYPE_DEVICE_CLASS, Class) ->
    {device_class, Class};
decode_field(?DATA_TYPE_DEVICE_ID, ID) ->
    {device_id, ID};
decode_field(?DATA_TYPE_LE_BLT_DEVICE_ADDR, Addr) ->
    {le_blt_device_addr, Addr};
decode_field(?DATA_TYPE_LE_ROLE, Role) ->
    {le_role, Role};
decode_field(Type, Field) ->
    {Type, Field}.

get_name(Adv) ->
    case proplists:get_value(name, Adv) of
	undefined ->
	    proplists:get_value(short_name, Adv);
	Name -> Name
    end.

utf8_name(Data) when is_binary(Data) ->
    unicode:characters_to_list(list_to_binary(name_list(Data))).

%% return list of bytes excluding zero termination
name_list(<<0,_/binary>>) -> [];
name_list(<<C,Cs/binary>>) -> [C|name_list(Cs)];
name_list(<<>>) -> [].
