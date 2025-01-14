-module(ebridgebot_tg_SUITE).
-compile(export_all).

%% API
-export([]).

-include_lib("eunit/include/eunit.hrl").
-include_lib("escalus/include/escalus.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("exml/include/exml.hrl").
-include_lib("xmpp/include/xmpp_codec.hrl").
-include_lib("xmpp/include/ns.hrl").
-include("ebridgebot.hrl").
-include("ebridgebot_tg.hrl").

-define(CONTENT_TYPE, "image/png").
-define(LANG, <<"en">>).

-import(ebridgebot, [wait_for_result/2, wait_for_result/4, wait_for_list/1, wait_for_list/2]).

all() ->
	[{group, main}].

groups() ->
	MainStories = [muc_story, subscribe_muc_story, link_scheduler_story, moderate_story, upload_story, reply_story],
	[{main, [sequence], MainStories}, {local, [sequence], MainStories}].

init_per_suite(Config) ->
	catch escalus:delete_users(Config),
	escalus:create_users(Config),
	application:stop(ebridgebot),
	escalus:init_per_suite(Config).

end_per_suite(Config) ->
	catch escalus:delete_users(Config),
	catch meck:unload(),
	application:start(ebridgebot),
	escalus:end_per_suite(Config).

init_per_testcase(upload_story, Config) ->
	meck:new(ebridgebot_tg, [no_link, passthrough]),
	meck:new(pe4kin, [no_link, passthrough]),
	init_per_testcase(muc_story, Config);
init_per_testcase(CaseName, Config) ->
	meck:new(ebridgebot_component, [no_link, passthrough]),
	meck:expect(ebridgebot_component, process_stanza, send_stanza_fun(self())),
	[BotArgs | _] = escalus_ct:get_config(tg_bots),
	Args = BotArgs#{component => escalus_ct:get_config(ejabberd_service),
					host => escalus_ct:get_config(ejabberd_addr),
					upload_host => escalus_ct:get_config(upload_host),
					password => escalus_ct:get_config(ejabberd_service_password),
					port => escalus_ct:get_config(ejabberd_service_port),
					rooms => []},

	{ok, Pid} =
		wait_for_result(
			fun() ->
				case ebridgebot_component:start(Args) of
					{error, {already_started, P}} ->
						exit(P, kill);
					Res -> Res
				end
			end,
			fun({ok, _}) -> true; (_) -> false end),
	
	[_Host, MucHost, Rooms] =
		[escalus_ct:get_config(K) || K <- [ejabberd_domain, muc_host, ebridgebot_rooms]],
	[begin
		 [Room, ChatId] = [proplists:get_value(K, Opts) || K <- [name, chat_id]],
		 case application:get_application(ejabberd) of
			 {ok, _} ->
				 catch mod_muc_admin:destroy_room(Room, MucHost),
				 timer:sleep(100);
			 _ -> ok
		 end,
		 Pid ! {add_room, ChatId, jid:to_string({Room, MucHost, <<>>})},
		 #{bot_id := BotId, rooms := [#muc_state{group_id = ChatId, state = {out, unsubscribed}}]} = ebridgebot_component:state(Pid),

		 Pid ! {linked_rooms, presence, available},
		 #{bot_id := BotId, rooms := [#muc_state{group_id = ChatId, state = {pending, unsubscribed}}]} = ebridgebot_component:state(Pid),
		 #{bot_id := BotId, rooms := [#muc_state{state = {in, _}}]} =
			 wait_for_result(fun() -> ebridgebot_component:state(Pid) end, %% wait for the room to be created and enter it
				 fun(#{rooms := [#muc_state{state = {in, _}}]}) -> true; (_) -> false end),
		 ok
	 end || {_, Opts} <- Rooms],
	[{component_pid, Pid} | maps:to_list(Args) ++ escalus:init_per_testcase(CaseName, Config)].


end_per_testcase(upload_story, Config) ->
	catch meck:unload(ebridgebot_tg),
	catch meck:unload(pe4kin),
	case application:get_application(ejabberd) of
		{ok, _} ->
			Host = hd(ejabberd_option:hosts()),
			UploadDir = binary_to_list(mod_http_upload_opt:docroot(Host)),
			Component = get_property(component, Config),
			file:del_dir_r(filename:join(UploadDir, binary_to_list(str:sha(<<$@, Component/binary>>))));
		_ -> ok
	end,
	end_per_testcase(muc_story, Config);
end_per_testcase(CaseName, Config) ->
	catch destroy_room(CaseName, Config),
	ok = ebridgebot_component:stop(get_property(component_pid, Config)),
	mnesia:delete_table(ebridgebot:bot_table(get_property(bot_id, Config))),
	catch meck:unload(),
	escalus:end_per_testcase(CaseName, Config).

destroy_room(CaseName, Config) ->
	[Pid, Component] = [get_property(K, Config) || K <- [component_pid, component]],
	[Rooms, MucHost] = [escalus_ct:get_config(K) || K <- [ebridgebot_rooms, muc_host]],
	[begin
		 RoomNode = get_property(name, Opts),
		 Iq = #iq{type = set, from = jid:decode(Component), to = jid:make(RoomNode, MucHost), sub_els = [#muc_owner{destroy = #muc_destroy{}}]},
		 escalus_component:send(Pid, xmpp:encode(Iq)),
		 case CaseName of
			 subscribe_muc_story -> ok;
			 _ -> receive
				      destroyed -> ct:comment("room destroyed")
			      after 5000 ->
					 ct:comment("room destroy timeout"),
					 {error, timeout}
			      end
		 end
	 end || {_, Opts} <- Rooms].

muc_story(Config) ->
	[RoomNode, ChatId] = [escalus_config:get_ct({ebridgebot_rooms, ebridgebot_test, K}) || K <- [name, chat_id]],
	MucHost = escalus_config:get_ct(muc_host),
	RoomJid = jid:to_string({RoomNode, MucHost, <<>>}),
	AliceNick = escalus_config:get_ct({escalus_users, alice, nick}),
	[BotId, Pid, _Component, BotName] = [get_property(Key, Config) || Key <- [bot_id, component_pid, component, bot_name]],
	escalus:story(Config, [{alice, 1}],
		fun(#client{jid = _AliceJid} = Alice) ->
			enter_room(Alice, RoomJid, AliceNick),
			escalus_client:wait_for_stanzas(Alice, 2),

			AliceMsg = <<"Hi, bot!">>, AliceMsg2 = <<"Hi, bot! Edited">>,
			AlicePkt = xmpp:set_subtag(xmpp:decode(escalus_stanza:groupchat_to(RoomJid, AliceMsg)), #origin_id{id = OriginId = ebridgebot:gen_uuid()}),
			escalus:send(Alice, xmpp:encode(AlicePkt)),
			escalus:assert(is_groupchat_message, [AliceMsg], escalus:wait_for_stanza(Alice)),
			[_] = wait_for_list(fun() -> mnesia:dirty_all_keys(ebridgebot:bot_table(BotId)) end, 1),
			[#xmpp_link{origin_id = OriginId, uid = TgUid = #tg_id{}, mam_id = MamId}] =
				wait_for_list(fun() -> ebridgebot:index_read(BotId, OriginId, #xmpp_link.origin_id) end, 1),
			?assert(is_binary(MamId)),
			AlicePkt2 = #message{type = groupchat, to = RoomJID = jid:decode(RoomJid), body = [#text{data = AliceMsg2}], %% edit message from xmpp
				sub_els = [#replace{id = OriginId}, #origin_id{id = OriginId2 = ebridgebot:gen_uuid()}]},
			escalus:send(Alice, xmpp:encode(AlicePkt2)),
			escalus:assert(is_groupchat_message, [AliceMsg2], escalus:wait_for_stanza(Alice)),
			[#xmpp_link{origin_id = OriginId, uid = TgUid = #tg_id{chat_id = ChatId, id = MessageId}}, %% add edit link to bot link table
				#xmpp_link{origin_id = OriginId2, uid = TgUid = #tg_id{}}] =
				wait_for_list(fun() -> ebridgebot:index_read(BotId, TgUid, #xmpp_link.uid) end, 2),

			AliceRetractPkt = #message{type = groupchat, to = RoomJID, %% retract from xmpp client
				sub_els = [#origin_id{id = ebridgebot:gen_uuid()}, #fasten_apply_to{id = OriginId2, sub_els = [#message_retract{}]}]},
			escalus:send(Alice, xmpp:encode(AliceRetractPkt)),
			#fasten_apply_to{id = OriginId2} = xmpp:get_subtag(xmpp:decode(escalus:wait_for_stanza(Alice)), #fasten_apply_to{}),
			[] = wait_for_list(fun() -> ebridgebot:index_read(BotId, TgUid, #xmpp_link.uid) end),
			[] = mnesia:dirty_all_keys(ebridgebot:bot_table(BotId)),

			TgAliceMsg = <<"Hello from telegram!">>, TgAliceMsg2 = <<"2: Hello from telegram!">>,
			Pid ! {pe4kin_update, BotName, tg_message(ChatId, MessageId + 1, AliceNick, TgAliceMsg)}, %% emulate sending message from Telegram
			TgAliceName = <<AliceNick/binary, " ", AliceNick/binary>>,
			escalus:assert(is_groupchat_message, [<<?NICK(TgAliceName), TgAliceMsg/binary>>], FromTgAlicePkt = escalus:wait_for_stanza(Alice)),
			#message{body = [#text{lang = ?LANG}]} = xmpp:decode(FromTgAlicePkt),
			TgUid2 = TgUid#tg_id{id = MessageId + 1},
			[#xmpp_link{uid = TgUid2, mam_id = MamId2}] =
				wait_for_result(fun() -> ebridgebot:index_read(BotId, TgUid2, #xmpp_link.uid) end,
					fun([#xmpp_link{mam_id = MamId2}]) when is_binary(MamId2) -> true; (_) -> false end) ,
			?assert(is_binary(MamId2)),

			%% emulate editing message from Telegram
			Pid ! {pe4kin_update, BotName, tg_message(<<"edited_message">>, ChatId, MessageId + 1, AliceNick, TgAliceMsg2)},
			escalus:assert(is_groupchat_message, [<<?NICK(TgAliceName), TgAliceMsg2/binary>>], escalus:wait_for_stanza(Alice)),
			[#xmpp_link{uid = TgUid2}, #xmpp_link{uid = TgUid2}] =
				wait_for_list(fun() -> ebridgebot:index_read(BotId, TgUid2, #xmpp_link.uid) end, 2),
			ok
		end).

subscribe_muc_story(Config) ->
	[RoomNode, ChatId] = [escalus_config:get_ct({ebridgebot_rooms, ebridgebot_test, K}) || K <- [name, chat_id]],
	MucHost = escalus_config:get_ct(muc_host),
	MucJid = jid:to_string({RoomNode, MucHost, <<>>}),
	AliceNick = escalus_config:get_ct({escalus_users, alice, nick}),
	[BotId, Pid, Component, BotName, Nick] = [get_property(Key, Config) || Key <- [bot_id, component_pid, component, bot_name, nick]],
	escalus:story(Config, [{alice, 1}],
		fun(#client{jid = _AliceJid} = Alice) ->
			enter_room(Alice, MucJid, AliceNick),
			escalus_client:wait_for_stanzas(Alice, 2),
			escalus_component:send(Pid, groupchat_presence(Component, MucJid, Nick, unavailable)),
			escalus:assert(is_presence, escalus:wait_for_stanza(Alice)),
			CreateTime = erlang:system_time(microsecond),
			Pid ! {linked_rooms, event, subscribe},
			#{bot_id := BotId, rooms := [#muc_state{group_id = ChatId, state = {out, subscribed}}]} =
				wait_for_result(fun() -> ebridgebot_component:state(Pid) end,
					fun(#{rooms := [#muc_state{state = {out, subscribed}}]}) -> true; (_) -> false end),

			AliceMsg = <<"Hi, bot!">>, _AliceMsg2 = <<"Hi, bot! Edited">>,
			AlicePkt = xmpp:set_subtag(xmpp:decode(escalus_stanza:groupchat_to(MucJid, AliceMsg)), #origin_id{id = OriginId = ebridgebot:gen_uuid()}),
			escalus:send(Alice, xmpp:encode(AlicePkt)),
			escalus:assert(is_groupchat_message, [AliceMsg], escalus:wait_for_stanza(Alice)),
			[_] = wait_for_list(fun() -> mnesia:dirty_all_keys(ebridgebot:bot_table(BotId)) end, 1),
			[#xmpp_link{origin_id = OriginId, uid = TgUid = #tg_id{id = MessageId}, mam_id = MamId}] =
				wait_for_list(fun() -> ebridgebot:index_read(BotId, OriginId, #xmpp_link.origin_id) end, 1),
			true = is_binary(MamId),
			TgAliceMsg = <<"Hello from telegram!">>,
			TgAliceName = <<AliceNick/binary, " ", AliceNick/binary>>,
			Pid ! {pe4kin_update, BotName, tg_message(ChatId, MessageId + 1, AliceNick, TgAliceMsg)}, %% emulate sending message from Telegram
			escalus:assert(is_groupchat_message, [<<?NICK(TgAliceName), TgAliceMsg/binary>>], escalus:wait_for_stanza(Alice)),
			TgUid2 = TgUid#tg_id{id = MessageId + 1},
			[#xmpp_link{uid = TgUid2, mam_id = _MamId2}] =
				wait_for_list(fun() -> ebridgebot:index_read(BotId, TgUid2, #xmpp_link.uid) end, 1),
%%			true = is_binary(MamId2),
			Pid ! {remove_old_links, CreateTime}, %% does not remove any link
			[_, _] = wait_for_list(fun() -> mnesia:dirty_all_keys(ebridgebot:bot_table(BotId)) end, 2),

			Pid ! {remove_old_links, erlang:system_time(microsecond)}, %% removes all links
			[] = wait_for_list(fun() -> mnesia:dirty_all_keys(ebridgebot:bot_table(BotId)) end),
			ok
		end).

moderate_story(Config) ->
	[RoomNode, ChatId] = [escalus_config:get_ct({ebridgebot_rooms, ebridgebot_test, K}) || K <- [name, chat_id]],
	MucHost = escalus_config:get_ct(muc_host),
	RoomJid = jid:to_string({RoomNode, MucHost, <<>>}),
	AliceNick = escalus_config:get_ct({escalus_users, alice, nick}),
	[BotId, Pid, Component, BotName] = [get_property(Key, Config) || Key <- [bot_id, component_pid, component, bot_name]],
	escalus:story(Config, [{alice, 1}],
		fun(#client{jid = AliceJid} = Alice) ->
			DiscoInfoIq = #xmlel{attrs = Attrs} =
				escalus_stanza:iq_get(?NS_DISCO_INFO, []),
			escalus:send(Alice, DiscoInfoIq#xmlel{attrs = [{<<"to">>, RoomJid} | Attrs]}),
			#iq{sub_els = [#disco_info{features = Features}]} = xmpp:decode(escalus:wait_for_stanza(Alice)),
			true = lists:member(?NS_MESSAGE_MODERATE, Features),

			enter_room(Alice, RoomJid, AliceNick),
			escalus_client:wait_for_stanzas(Alice, 2),
			ModeratorIq = #iq{type = set, from = jid:decode(Component), to = jid:decode(RoomJid),
								sub_els = [#muc_admin{items = [#muc_item{affiliation = admin, jid = jid:decode(AliceJid)}]}]},
			escalus_component:send(Pid, xmpp:encode(ModeratorIq)), %% set Alice as admin

			AliceMsg = <<"Hi, bot!">>, ComponentMsg = <<"Hi, Alice!">>,
			AlicePkt = xmpp:set_subtag(xmpp:decode(escalus_stanza:groupchat_to(RoomJid, AliceMsg)), #origin_id{id = OriginId = ebridgebot:gen_uuid()}),
			escalus:send(Alice, xmpp:encode(AlicePkt)),
			escalus:assert(is_groupchat_message, [AliceMsg], escalus:wait_for_stanza(Alice)),
			[#xmpp_link{origin_id = OriginId, uid = #tg_id{id = MessageId}, mam_id = MamId}] =
				wait_for_list(fun() -> ebridgebot:index_read(BotId, OriginId, #xmpp_link.origin_id) end, 1),

			Pid ! {pe4kin_update, BotName, tg_message(ChatId, MessageId + 1, AliceNick, ComponentMsg)}, %% emulate sending message from Telegram
			TgAliceName = <<AliceNick/binary, " ", AliceNick/binary>>,
			escalus:assert(is_groupchat_message, [<<?NICK(TgAliceName), ComponentMsg/binary>>], Pkt = escalus:wait_for_stanza(Alice)),
			#mam_archived{id = MamId2} = xmpp:get_subtag(xmpp:decode(Pkt), #mam_archived{}),
			AliceModerateIq =
				#iq{type = set, from = jid:decode(AliceJid), to = RoomJID = jid:decode(RoomJid),
					sub_els = [#fasten_apply_to{id = MamId2, sub_els = [#message_moderate{retract = #message_retract{}, reason = <<"removed by admin">>}]}]},
			escalus:send(Alice, xmpp:encode(AliceModerateIq)),
			escalus:assert(is_iq_result, escalus:wait_for_stanza(Alice)),
			RoomAliceNick = jid:replace_resource(RoomJID, AliceNick),
			#fasten_apply_to{sub_els = [#message_moderated{by = RoomAliceNick}]} =
				xmpp:get_subtag(xmpp:decode(escalus:wait_for_stanza(Alice)), #fasten_apply_to{}),
			[] = wait_for_list(fun() -> ebridgebot:index_read(BotId, MamId2, #xmpp_link.mam_id) end),
			[_] = ebridgebot:index_read(BotId, MamId, #xmpp_link.mam_id),
			ok
		end).

link_scheduler_story(Config) ->
	[_RoomNode, ChatId] = [escalus_config:get_ct({ebridgebot_rooms, ebridgebot_test, K}) || K <- [name, chat_id]],
	[Pid, BotId] = [get_property(K, Config) || K <- [component_pid, bot_id]],
	#{link_scheduler_ref := _} = ebridgebot_component:state(Pid), %% scheduler by default

	%% add 3 messages with different time of creation
	Table = ebridgebot:bot_table(BotId),
	ebridgebot:write_link(BotId, ebridgebot:gen_uuid(), Uid = #tg_id{chat_id = ChatId, id = MessageId = 1}),
	mnesia:dirty_write({Table, erlang:system_time(microsecond) - 2000000, ebridgebot:gen_uuid(), [], Uid2 = Uid#tg_id{id = MessageId + 1}}),
	mnesia:dirty_write({Table, erlang:system_time(microsecond) - 800000, ebridgebot:gen_uuid(), [], Uid2#tg_id{id = MessageId + 1}}),

	Pid ! {link_scheduler, 200, 1000}, %% start new scheduler
	%% to make sure that the messages are deleted one by one
	[I = length(wait_for_list(fun() -> mnesia:dirty_all_keys(Table) end, I)) || I <- lists:reverse(lists:seq(0, 2))],
	Pid ! stop_link_scheduler, %% start new scheduler
	false = maps:is_key(link_scheduler_ref, ebridgebot_component:state(Pid)), %% to make sure that scheduler is stopped
	Config.

upload_story(Config) ->
	[RoomNode, ChatId] = [escalus_config:get_ct({ebridgebot_rooms, ebridgebot_test, K}) || K <- [name, chat_id]],
	[MucHost, UploadHost] = [escalus_config:get_ct(K) || K <- [muc_host, upload_host]],
	MucJid = jid:to_string({RoomNode, MucHost, <<>>}),
	AliceNick = escalus_config:get_ct({escalus_users, alice, nick}),
	[BotId, Pid, _Component, BotName] = [get_property(Key, Config) || Key <- [bot_id, component_pid, component, bot_name]],
	escalus:story(Config, [{alice, 1}],
		fun(#client{jid = _AliceJid} = Alice) ->
			DiscoInfoIq = #iq{type = get, sub_els = [#disco_info{}], to = UploadJID = jid:decode(UploadHost)},
			escalus:send(Alice, xmpp:encode(DiscoInfoIq)),
			#iq{sub_els = [#disco_info{xdata = Xs, features = Features}]} = xmpp:decode(escalus:wait_for_stanza(Alice)),
			[true = lists:member(NS, Features) || NS <- namespaces()],

			Sizes = lists:flatten(
				[case xmpp_util:get_xdata_values(<<"FORM_TYPE">>, X) of
					 [NS] ->
						 [Size] = xmpp_util:get_xdata_values(<<"max-file-size">>, X),
						 true = erlang:binary_to_integer(Size) > 0,
						 {NS, erlang:binary_to_integer(Size)};
					 _ -> []
				 end || X <- Xs, NS <- namespaces()]),
			ct:comment("Get max sizes for namespaces: ~p", [Sizes]),
			Size = p1_rand:uniform(1, 1024),
			SlotIq = #iq{id = Id = ebridgebot:gen_uuid(), type = get, to = UploadJID,
				sub_els = [#upload_request_0{filename = filename(), size = Size, 'content-type' = <<?CONTENT_TYPE>>, xmlns = ?NS_HTTP_UPLOAD_0}]},

			escalus:send(Alice, xmpp:encode(SlotIq)),
			#iq{id = Id, type = result, sub_els = [#upload_slot_0{get = GetURL, put = PutURL, xmlns = ?NS_HTTP_UPLOAD_0}]} =
				xmpp:decode(escalus:wait_for_stanza(Alice)),
			Data = p1_rand:bytes(Size),
			ct:comment("Putting ~B bytes to ~s", [size(Data), PutURL]),
			{ok, {{"HTTP/1.1", 201, _}, _, _}} =
				httpc:request(put, {binary_to_list(PutURL), [], ?CONTENT_TYPE, Data}, [], []),

			ct:comment("Getting ~B bytes from ~s", [size(Data), PutURL]),
			{ok, {{"HTTP/1.1", 200, _}, _, Data}} =
				httpc:request(get, {binary_to_list(GetURL), []}, [], [{body_format, binary}]),
			ct:comment("Checking returned body"),

			enter_room(Alice, MucJid, AliceNick),
			escalus_client:wait_for_stanzas(Alice, 2),
			Extensions = [<<"png">>, <<"mp4">>, <<"mp3">>, <<"oga">>, <<"txt">>],
			[begin
				 FileName = filename(Ext),
				 meck:expect(ebridgebot_tg, get_file, fun(_) -> {ok, Data} end),
				 meck:expect(pe4kin, get_file, fun(_, _) -> {ok, #{<<"file_path">> => FileName, <<"file_size">> => Size}} end),
				 Pid ! {pe4kin_update, BotName, tg_upload_message(MessageId, ChatId, FileName, Size, <<"TesBotName">>, <<"Hello, upload!">>)},
				 UploadPkt = #message{id = OriginId, body = [#text{data = <<"from TesBotName TesBotName\n \nHello, upload!\n", Url/binary>>}]}
					 = xmpp:decode(escalus:wait_for_stanza(Alice)),
				 #message_upload{body = [#message_upload_body{url = Url}]} = xmpp:get_subtag(UploadPkt, #message_upload{}),
				 ct:comment("received link message: ~s", [Url]),
				 {ok, {{"HTTP/1.1", 200, _}, _, Data}} =
					 wait_for_result(fun() ->
						 httpc:request(get, {binary_to_list(Url), []}, [], [{body_format, binary}]) end,
						 fun({ok, {{"HTTP/1.1", 200, _}, _, _}}) -> true; (_) -> false end),
				 [#xmpp_link{origin_id = OriginId, mam_id = MamId}] =
					 wait_for_list(fun() -> ebridgebot:index_read(BotId, OriginId, #xmpp_link.origin_id) end, 1),
				 #{upload := Upload} = ebridgebot_component:state(Pid),
				 Upload = #{},
				 ?assert(is_binary(MamId)),
				 ct:comment(<<FileName/binary, " is uploaded successfully">>)
			 end || {Ext, MessageId} <- lists:zip(Extensions, lists:seq(1, length(Extensions)))],
			ok
		end).

reply_story(Config) ->
	[RoomNode, ChatId] = [escalus_config:get_ct({ebridgebot_rooms, ebridgebot_test, K}) || K <- [name, chat_id]],
	MucHost = escalus_config:get_ct(muc_host),
	RoomJid = jid:to_string({RoomNode, MucHost, <<>>}),
	[AliceNick, BobNick] = [escalus_config:get_ct({escalus_users, User, nick}) || User <- [alice, bob]],
	[BotId, Pid, _Component, BotName, BotNick] = [get_property(Key, Config) || Key <- [bot_id, component_pid, component, bot_name, nick]],
	escalus:story(Config, [{alice, 1}, {bob, 1}],
		fun(#client{jid = _AliceJid} = Alice,
			#client{jid = _BobJid} = Bob) ->
			DiscoInfoIq = #xmlel{attrs = Attrs} =
				escalus_stanza:iq_get(?NS_DISCO_INFO, []),
			escalus:send(Alice, DiscoInfoIq#xmlel{attrs = [{<<"to">>, RoomJid} | Attrs]}),
			#iq{sub_els = [#disco_info{features = Features}]} = xmpp:decode(escalus:wait_for_stanza(Alice)),
			true = lists:member(?NS_REPLY, Features),
			Clients = [Alice, Bob],
			enter_room(Alice, RoomJid, AliceNick),
			escalus_client:wait_for_stanzas(Alice, 2),
			enter_room(Bob, RoomJid, BobNick),
			[escalus_client:wait_for_stanzas(Client, 2) || Client <- Clients],

			AliceMsg = <<"Hi, Bob!">>, ReplyMsg = <<"Hi, Alice!">>,
			AlicePkt = xmpp:set_subtag(Pkt = xmpp:decode(escalus_stanza:groupchat_to(RoomJid, AliceMsg)), #origin_id{id = OriginId = ebridgebot:gen_uuid()}),
			escalus:send(Alice, xmpp:encode(AlicePkt)),
			escalus:assert(is_groupchat_message, [AliceMsg], escalus:wait_for_stanza(Alice)),
			[#xmpp_link{origin_id = OriginId, uid = #tg_id{id = MessageId}}] =
				wait_for_list(fun() -> ebridgebot:index_read(BotId, OriginId, #xmpp_link.origin_id) end, 1),

			TgAliceName = <<AliceNick/binary, " ", AliceNick/binary>>,
			TgReply =
				#{<<"reply_to_message">> =>
					#{<<"from">> => #{<<"username">> => BotName, <<"first_name">> => BotNick, <<"language_code">> => ?LANG, <<"is_bot">> => true},
						<<"message_id">> => MessageId,
						<<"text">> => TgAliceText = <<?NICK(TgAliceName), AliceMsg/binary>>}},
			From = #{<<"first_name">> => BobNick, <<"language_code">> => ?LANG, <<"is_bot">> => false},
			TgReplyMsg = tg_message(ChatId, MessageId + 1, From, ReplyMsg, TgReply),
			Pid ! {pe4kin_update, BotName, TgReplyMsg}, %% emulate sending reply message from Telegram

			#reply{id = OriginId} = xmpp:get_subtag(ReplyPkt = #message{body = [#text{data = ReplyText}]} =
				xmpp:decode(escalus:wait_for_stanza(Alice)), #reply{}),
			#feature_fallback{body = #feature_fallback_body{start = Start, 'end' = End}} = xmpp:get_subtag(ReplyPkt, #feature_fallback{}),
			OriginalText = binary:part(ReplyText, Start, End - Start),
			AliceMsg2 = binary:replace(TgAliceText, <<"\n">>, <<">">>, [global, {insert_replaced, 0}]),
			OriginalText = <<$>, BotNick/binary,"\n>", AliceMsg2/binary>>,
			ct:comment(OriginalText),

			AliceReplyPkt = (DecodedPkt = xmpp:decode(Pkt))#message{body = [#text{data = ReplyMsg}],
				sub_els = [#origin_id{id = ReplyToId = ebridgebot:gen_uuid()}, #reply{id = OriginId, to = jid:decode(RoomJid)}]},
			escalus:send(Alice, xmpp:encode(AliceReplyPkt)),
			#reply{} = xmpp:get_subtag(xmpp:decode(escalus:wait_for_stanza(Alice)), #reply{}),
			[#xmpp_link{origin_id = ReplyToId, uid = #tg_id{}}] =
				wait_for_list(fun() -> ebridgebot:index_read(BotId, ReplyToId, #xmpp_link.origin_id) end, 1),

			ReplyEditMsg = <<"Hi, Alice! (edited)">>,
			AliceReplyEditPkt = AliceReplyPkt#message{body = [#text{data = ReplyEditMsg}],
				sub_els = [#origin_id{id = ReplyToId2 = ebridgebot:gen_uuid()}, #reply{id = OriginId, to = jid:decode(RoomJid)}, #replace{id = ReplyToId}]},

			escalus:send(Alice, xmpp:encode(AliceReplyEditPkt)),
			#reply{} = xmpp:get_subtag(#message{body = [#text{data = ReplyEditMsg}]} = xmpp:decode(escalus:wait_for_stanza(Alice)), #reply{}),
			[#xmpp_link{origin_id = ReplyToId2, uid = #tg_id{}}] =
				wait_for_list(fun() -> ebridgebot:index_read(BotId, ReplyToId2, #xmpp_link.origin_id) end, 1),
			State = ebridgebot_component:state(Pid), %% same state

			%% send fallback reply packet
			AliceReplyMsg = binary:replace(AliceMsg, <<"\n">>, <<">">>, [global, {insert_replaced, 0}]),
			RepliedAliceText = <<$>, AliceNick/binary, "\n>", AliceReplyMsg/binary>>,
			AliceFullReplyMsg = <<RepliedAliceText/binary, $\n, ReplyMsg/binary>>, %% message with fallback reply
			AliceReplyPkt2 = DecodedPkt#message{
				body = [#text{data = AliceFullReplyMsg}],
				sub_els = [#origin_id{id = ReplyToId3 = ebridgebot:gen_uuid()},
					#reply{id = OriginId, to = jid:decode(RoomJid)},
					#feature_fallback{body = #feature_fallback_body{start = 0, 'end' = byte_size(RepliedAliceText) + 1}}]},
			meck:expect(ebridgebot_tg, send_message, send_message_fun(self())),
			escalus:send(Alice, xmpp:encode(AliceReplyPkt2)),
			#feature_fallback{} = xmpp:get_subtag(ReplyFallbackPkt = xmpp:decode(escalus:wait_for_stanza(Alice)), #feature_fallback{}),
			#reply{} = xmpp:get_subtag(ReplyFallbackPkt, #reply{}),
			escalus_client:wait_for_stanzas(Bob, 6),
			[#xmpp_link{origin_id = ReplyToId3, uid = #tg_id{}}] =
				wait_for_list(fun() -> ebridgebot:index_read(BotId, ReplyToId3, #xmpp_link.origin_id) end, 1),
			receive
				#{text := ReplyMsg} ->
					ct:comment("reply: ~s", [ReplyMsg]);
				#{text := ReplyWrongText} ->
					ct:comment("reply wrong: ~s", [ReplyWrongText]),
					?assert(false)
			after 2000 ->
				ct:comment("reply timeout"),
				?assert(false)
			end
		end).

%% tg test API
tg_message(ChatId, MessageId, Username, Text) when is_integer(ChatId) ->
	tg_message(<<"message">>, ChatId, MessageId, Username, Text, #{}).
tg_message(ChatId, MessageId, Username, Text, #{} = AddedMap) when is_integer(ChatId) ->
	tg_message(<<"message">>, ChatId, MessageId, Username, Text, AddedMap);
tg_message(Message, ChatId, MessageId, Username, Text) ->
	tg_message(Message, ChatId, MessageId, Username, Text, #{}).
tg_message(Message, ChatId, MessageId, Username, Text, AddedMap)
	when is_binary(Username) andalso (Message == <<"message">> orelse Message == <<"edited_message">>) ->
	From = #{	<<"id">> => rand:uniform(10000000000),
		<<"is_bot">> => false, %% TODO update if <<"is_bot">> == true
		<<"language_code">> => ?LANG,
		<<"first_name">> => Username,
		<<"last_name">> => Username,
		<<"username">> => Username},
	tg_message(Message, ChatId, MessageId, From, Text, AddedMap);
tg_message(Message, ChatId, MessageId, #{} = From, Text, #{} = AddedMap) %% emulate Telegram message
	when Message == <<"message">>; Message == <<"edited_message">> ->
	Msg = #{<<"chat">> => #{<<"id">> => ChatId, <<"title">> => <<"RoomTitle">>, <<"type">> => <<"group">>},
			<<"date">> => erlang:system_time(second),
			<<"from">> => From,
			<<"message_id">> => MessageId},
	Msg2 = case is_binary(Text) of true -> Msg#{<<"text">> => Text}; _ -> Msg end,
	#{Message => maps:merge(AddedMap, Msg2), <<"update_id">> => rand:uniform(10000000000)}.

tg_upload_message(MessageId, ChatId, Filename, FileSize, Username, Caption) ->
	UploadData = #{<<"file_id">> => ebridgebot:gen_uuid(), <<"file_size">> => FileSize},
	UploadMap =
		case hd(mimetypes:filename(Filename)) of
			<<"audio/oga">>         -> #{<<"voice">> => UploadData};
			<<"audio/", _/binary>>  -> #{<<"audio">> => UploadData};
			<<"image/", _/binary>>  -> #{<<"photo">> => lists:duplicate(3, UploadData)};
			<<"video/", _/binary>>  -> #{<<"video">> => UploadData};
			_                       -> #{<<"document">> => UploadData}
		end,
	tg_message(ChatId, MessageId, Username, [], UploadMap#{<<"caption">> => Caption}).

%% test API
get_property(PropName, Proplist) ->
	case lists:keyfind(PropName, 1, Proplist) of
		{PropName, Value} ->
			Value;
		false ->
			throw({missing_property, PropName})
	end.

groupchat_presence(From, To, Nick) ->
	groupchat_presence(From, To, Nick, available).
groupchat_presence(#client{jid = From}, To, Nick, Type) ->
	groupchat_presence(From, To, Nick, Type);
groupchat_presence(From, To, Nick, Type) when is_binary(From), is_binary(To) ->
	xmpp:encode(#presence{type = Type, from = jid:make(From), to = jid:replace_resource(jid:decode(To), Nick), sub_els = [#muc{}]}).

enter_room(Client, RoomJid, Nick) ->
	escalus:send(Client, groupchat_presence(Client, RoomJid, Nick)),
	escalus_client:wait_for_stanzas(Client, 2). %% Client wait for 2 presences from ChatRoom

namespaces() ->
	[?NS_HTTP_UPLOAD_0, ?NS_HTTP_UPLOAD, ?NS_HTTP_UPLOAD_OLD].

filename() ->
	filename(<<"png">>).

filename(Ext) ->
	<<(p1_rand:get_string())/binary, $., Ext/binary>>.

handle_info(Info, Client, State) ->
	meck:passthrough([Info, Client, State]).

send_stanza_fun(Pid) ->
	fun(Stanza, Client, State) ->
		case xmpp:decode(Stanza) of
			#presence{type = unavailable, sub_els = [#muc_user{destroy = #muc_destroy{}}]} = Presence ->
				Res = meck:passthrough([Presence, Client, State]),
				Pid ! destroyed,
				Res;
			_ -> meck:passthrough([Stanza, Client, State])
		end
	end.

send_message_fun(Pid) ->
	fun(#{reply_to := _} = State) ->
			Res = meck:passthrough([State]),
			Pid ! State, Res;
		(State) ->
			meck:passthrough([State])
	end.
