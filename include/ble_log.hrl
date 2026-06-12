-ifndef(__BLE_LOG_HRL__).
-define(__BLE_LOG_HRL__, true).

-define(LOG_LEVEL_NONE, -1).
-define(LOG_LEVEL_EMERGENCY, 0).
-define(LOG_LEVEL_ALERT,     1).
-define(LOG_LEVEL_CRITICAL,  2).
-define(LOG_LEVEL_ERROR,     3).
-define(LOG_LEVEL_WARNING,   4).
-define(LOG_LEVEL_NOTICE,    5).
-define(LOG_LEVEL_INFO,      6).
-define(LOG_LEVEL_DEBUG,     7).

-define(BLE_LOG_LEVEL, ?LOG_LEVEL_DEBUG).
%%-define(BLE_LOG_LEVEL, ?LOG_LEVEL_ERROR).
%%-define(BLE_LOG_LEVEL, ?LOG_LEVEL_INFO).

-define(debug(Fmt),   ?ble_log(?LOG_LEVEL_DEBUG,"DEBUG: " Fmt ,[])).
-define(warning(Fmt), ?ble_log(?LOG_LEVEL_WARNING,"WARNING: " Fmt,[])).
-define(info(Fmt),    ?ble_log(?LOG_LEVEL_INFO,"INFO: " Fmt,[])).
-define(error(Fmt),   ?ble_log(?LOG_LEVEL_ERROR,"ERROR: "Fmt,[])).

-define(debug(Fmt, As),   ?ble_log(?LOG_LEVEL_DEBUG,"DEBUG: " Fmt ,As)).
-define(warning(Fmt, As), ?ble_log(?LOG_LEVEL_WARNING,"WARNING: " Fmt,As)).
-define(info(Fmt, As),    ?ble_log(?LOG_LEVEL_INFO,"INFO: " Fmt,As)).
-define(error(Fmt, As),   ?ble_log(?LOG_LEVEL_ERROR,"ERROR: "Fmt,As)).

-define(ble_log(Level, Fmt, As),
	case Level =< ?BLE_LOG_LEVEL of
	    true ->
		io:format(Fmt "\n", As);
	    false ->
		ok
	end).

-endif.
