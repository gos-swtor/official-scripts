-- Incoming combat meter model. No casts, file I/O, or tick registrations.
-- Damage/lifecycle/interrupt rows come only from gos.events.combat().
-- CC transitions are explicitly snapshot OBSERVATIONS, not fabricated events.
local ActorLabels = require("ui.actor_labels")
local M = { build_id = "2026-09-15-incoming-actor-ssot-r2" }
local MAX_SOURCES, MAX_ABILITIES, MAX_SOURCE_ABILITIES = 64, 64, 32
local HISTORY, MAX_EFFECTS = 2048, 512
local BUCKETS, BUCKET_MS = 24, 2500
M.history_capacity, M.bucket_count, M.bucket_ms = HISTORY, BUCKETS, BUCKET_MS
local CC = {}
M.cc_catalog_entries = 0
local function add_cc(kind, keys)
    for key in keys:gmatch("%x+") do
        assert(#key == 16 and CC["effectdef:" .. key] == nil, "Invalid/duplicate CC definition")
        CC["effectdef:" .. key] = kind
        M.cc_catalog_entries = M.cc_catalog_entries + 1
    end
end
-- Installed-client audit: docs/research/pvp_cleanse_effects_20260907.csv
-- Includes control-tagged negative effects regardless of cleanse eligibility.
-- 533 definitions; no name/class/cast heuristics. NPC-only branches unaudited.
-- Audit SHA256: 8f6bf436a04bdfede7d6914a867e64d018c13c8ac83b84f37e54de43b8fba85a
add_cc("Mez", [[
0323A3897BC0D687 05152AB8C2A6852C 089D99FF490A0512 0D53B00856AE855A 0EE284347753D0F4 1544E2E134CAB604
1582F7D64CE81E06 191EC8B2ED3D0E15 2048B78563D0212D 247E466221CE1519 2645658CDFE644A3 2B4E4D6F0EE4F723
2BA92B0A8586E30E 2D7A1F83ECE6269F 2EEF2D7E15999B8E 31118A05BA39339E 3413118BAA5ACDA6 3695BEFA17C46FEC
395A601E6532AB40 3A81601D667C3C9F 417F62C42843848A 46EFB6B8B596D915 494267914EA5A0EA 585BCC477C8BDCE8
5FF9DAD4EEAE0C24 62F810DF8C4114E3 666B53FFD1F3F888 6A9DEA73E558BF10 7AA130DBEFB648F2 856CC027FBF614A8
8B22A5A2784371E9 906027FDFE748A47 90D43C96E92EC532 9144FBFC11641C91 9557A379B8E81B9C AA3886AA453CBC3A
AD721491EAA792DE AE80583BAA45EFE7 AEC122B27E54DC43 B6A3733089FD6996 CF00992530CCF835 D01DD26196F54C68
D5A637B434A9C60D DAACD70313F3E262 DB454C0CE539D9A1 DBA123CABF2C9A68 E065770E3734C35F E8E615CC679890AA
E94FCB5DA064E5C8 ED2B77E397D5B57D F192164A55B2443F F40D572DD7E8688A FA97E4319C178EFC
]])
add_cc("Root", [[
022142C2EB675224 037A2058545AD5BA 0472601A83825A5C 04C77EFF99F8927E 0A9047AB8C7FA0E4 1162651E1F37B71D
1295A1556D8199CD 12A924704502A2CC 198ED72A314CE6A3 1A2F60A1DF9EC9A1 1DF4AE209F480262 1E6F4FE3F28EA850
23B4B90172CB06B0 2465534A1CC03FFC 2778B1EF337A08E6 2A872D88D93841DD 2B44F23FCDD701E4 32FFE89D260483C4
359FEF696027E027 36E0F1EF87423CCA 376412BC4E085630 3AE0040A9A879682 3F6A8362EA5B0A1C 408CEBD7B50AEAE5
41785E8749F15BD0 43268D8E9FFFF5C0 4449B2E416058950 46B9F7E4BAE22823 4932EE74D6FE1C79 513A65B3A45A5E23
5321CDA030428B4F 5811CD0690E51CEB 5D143151ED76CC2C 5E3ED1C575CEE0E1 6103218C0A983EE0 654D57F32F8A02B1
68F3DE3F1C14FD02 6BC1FE252D7C0DFB 71D7F1007CAFF72E 73552A4874E6BB9A 76ABB944456D0AD0 76FE8AC8456CC293
775F920D79D2E870 787F0CB1B8316D14 7A3E6AFD5A98746F 7CF92E3843C7A15E 7EA043C218C064FC 82BFA23DDD3611FC
848E43E3D8591387 84C20D7A44A6B728 86024148A23B152E 8A80BE65DD597975 8FF433B2012109C8 973CC2645E857882
9873F0891A75AC4A 9B0B273EE6570887 9F0168249F1275B8 9F6BD1BF4E11C6DD A133169F05579AE1 A295709E873D2AC2
A72B1074AD6F0628 A75ED34E157A8CBF ACF96A1C69E8DB71 AE12BA40E7EA935E BB41B678E2FA3EF9 BC12DC2F39F6C506
BFC034B07A47C089 C17216CAB4E4DF42 CA718FA6DBC3B20D CF05855F3AADBF6F D592AB4A0C8D8D80 D9A49260BEE5DE44
DC0EA1B4E8023F9D DE4D4E9022877A98 DEEA02B6A9B25504 DFB97BDF539FAFFF E00B6A6D99D95CBC E0AE26CD9BC6FBD1
E1EABA4F37111493 E7B5B6B1D3797CB5 E851A5AFBB24E7CA EA56204F28095748 EABDDD831EAC60D7 EE31D75A33C762A3
EF08AC64E50119B8 EFAF86D2ED32F768 F300DDD4DC27F952 F302A27EA06DF260 F623DDF2D1D8D007 F71746C942DCAB95
F76D807CB9A56F62 F914A790E285A101 FA0D4689EA3D83CE FFA60759096C7B2A
]])
add_cc("Silence", [[
040F8666EB95E554 0EB05CB9D51A390E 10E8D06FA8720E17 14864322E593C0A2 1BA508B41A6B27B6 1EF03149816FBEF7
23EBB1439630B4B7 293B2825BAAA1196 2C26A1B777E33BBA 3761BC3058A081F6 4BD8EB5998927B81 69D1087053068E68
6FF71164348D9E9A 7E6CAE596405625A BD6FC646D57BCCC7 C5BE63BC023CD261 C838632231CAD5AC DDA7FE9CD7E65E55
EA08FC817335D3D0 FEDBF0B1DB373226
]])
add_cc("Slow", [[
0090C5406F53C758 030ED362BAFD8245 065D498B9AAF3CCE 06A2FC5066C9BC10 0711D5B62B1F6CCB 0837BD0E8E92CD77
086D126B75C7E9D7 0A677CE6BB9440EC 0D53EDC0CBF51927 0DF784EAD7961C3F 0E0247F8781AD35E 0E6CCFE52445D414
0F4ACC9C004A1692 0FB67E5FF1EE447C 1038C41159890463 10990484B93EA553 1292A5AFBBB74212 151810E1EE750E8D
164682E87BA879DF 16A49B4B787CDA47 179C24A96047FE5A 17F0CD7B237A6288 18B242F18EC0D027 19F660D81409FC7C
1E65C85B54C190E5 23AB3DA61BC789D3 242249AFDEDCC3DB 249D4B0B724FBC03 27363DC63C0BFF48 2762C49734DB95C6
29B9F52F3AE5E139 2A97F302D1A8E3A4 2B3DB54586BA1938 2B57EAD9A1C3DEE9 2B5C4D0293228282 2C1C2211AA3F4F4F
2D23FF0C45263C1C 2D7C42653D7A62A3 305AA5B0350863E9 30A1B8F76351C71A 32ADFDBA9D111B13 33BBE1B469220D90
343290E9F6DF3881 355EF1FA117B82BA 35CD7F478F1EE0A7 36921444F4DC4CB7 372CD84F0B83A0A5 37B71CE3A819208E
386BD74A1E2A6BFF 3A3261185B534ECC 3AB223C10BC1A1A1 3B09C93B6E731730 3CAAD162282A3BCE 3DCB8867FDE95376
3E4BE6F6931FE51E 3E87A4C608BA7FA2 3E9FDD986FCED948 3F32BB385CCBD6A1 41B91EF915C06F5D 4448F18D2FCE56C5
46D5175D13261BA9 48C1A600FF0B00E1 4933C4E3E73A7C44 4B39B82BCB2102EA 4CBBE9D70AB10B09 5010B99606BE3CB1
5368A11672B90E35 56369185AE1B5EB8 577C4DAFE787ACBD 59E28D4504C4B664 5A81523A0253C137 5BE642FCEE5209D8
5D6ACE3BFAD8862D 5EF396CD3F2B626E 5F397C32CFBE2CE3 60AC11EB79975699 6158DE82FB23EA35 6312F3845C57BB00
651EE2D07B3972D2 65D68527D1B348D9 67C4426D648C2E41 68E74DE5A3D0494B 6A06577BEBB9D661 6A59C9FE0F2E44D7
6BFA276FDB1F9494 6C90C7E8C17E7C4C 6CDEF7F846F10468 6FAB2BCB3C9807BF 7067EC811BFC8BA4 722EAB02491E7A69
74044419750753EF 7688412EFF986AE6 768CB86214867FD5 76AD64BC94A80670 782FD1D2FC4C11AF 78E74F3B8F50A00F
79440394D6FCFAEE 7B0F66F8772E9390 7C8BCF90761606FE 7CED24357E1E4618 7F2AA09A848CAE54 8056047DE83FF0E8
80FC7553E7BC22C7 81D457D350FC6BB5 8335D2A869A52769 83B8DADCC4C965A2 85B8FD64174C653B 861C208644EDD263
86C4A000A703BF2C 8957EB00561DD83E 8A680C43452F19D4 8DD650B079EF3833 9068E63B5E870E85 911825EBB45877CB
9273E39E8CE81543 934330D44D187991 94D96F056B7814B0 963D55FB6A91BA26 9683E1B653249807 96A245F7AE82C183
98171D13485E7F2E 996C2FEB76FF952C 9B277B242C9CDC2D 9DE797DA48E80806 9E468D2B12956F93 A0A1639B40CBB894
A0D1F7CC60310C18 A1F8CC71D6DC706D A35002243D4A207A A3F5A6141C15460D A4E66C6C7750D67B A66E8FFD518C96B7
A7E20EC60CB53CFA A8FFE1CE9101CEB1 A937C3402F93B372 A93CC56CF41F34E9 AB1425587329BF5C ABDB8F52B028FC3A
AC754CDEBB36594E AE5BEEE7E4445687 AFAB67D9013BCC90 AFF8C370BF1BD7A5 B02858CFEF8817B1 B20528BD2CAA4AC7
B33DB6FFC543FF6A B49C8300CA4366AF B64461E54416BB53 B7007D3123DF1748 B9E7FE63FEF0AF7D BA0C26E53454FEB2
BB0CBBAB90484AD4 BB8F9092D3542336 BCF9B5D11FA4F387 BE51D5C53A4D79D9 BE9D11B4830E56BA BF8D68AC14C8D5F0
BFB9A0A76AC55487 C0805A2EE8F8BF61 C0AF29138F7814C0 C15ED1E2B40396C6 C1827646590832AC C1A88DE86A16BD01
C1ACDD9F1001184B C22767CE381906D2 C2CBBBC9776A6928 C2FDA310B50E6620 C30195096626681D C30773EA0DCE26D5
C556F840EEAE00FC C795303ECBA4E859 C7CE5CFF52423A0B CA1ECFB92DD3F6F8 CAC3D32AADE84480 CC0850DD74F16D7E
CC284131D46B03B5 D2E932B92D1930B0 D4349E28E1ADDD64 D55AF385E14E00BA D55F9B172EB02E5E D5932EBE06A90FD4
D7813B3C6E427362 D7E547BAABEDA89C DA11D9D664CF0C32 DB3B1A0E80F76EBE DD477C84BC40B01C DF12F28B892EFC94
E0D25640952A1A5C E5187484E05CA386 E661A31BA959A36B E98107E72FB44BD0 E9F685A1CC12EEF7 ECD90AEB46CA565D
EE1D89AEAFC4D830 F00B968682504B20 F10CB4500574C05C F137677708568547 F1ACD4FAEE2B7222 F20A7A6FEF73FEDF
F2F6433EDA57114C F38E0AC973995D70 F4CF9A4B3A3367BF F58F05F752BE82F1 FAB827CB06605904 FE589202627FCDB8
FE7E2110D208BE29 FE94163881656A0D FEC907B6D72B49AB
]])
add_cc("Stun", [[
015302E4EA627551 027C5F0A87EB6767 02BE3FCF7C0E4210 02F5E34E80BA6C3E 058952EC8F4D666E 05FF8A43F5448E69
06B8E5E66EEF8B50 07C02BE955AE51BE 0D367702265288B0 0DE75C787D4CC763 0DFDBE3079D1057F 0E3E17E3CEC095A5
0ED08E32B14DD4D8 11DBFA025F18BD78 13054006FFB9990E 139DBDD58CC98C03 1A302A59E5BCB601 1A4E43E16E54B82C
1B9F2ED175898616 1CD3718F6FFDA551 1ED0B3A996B7F06A 20947E667F6F42C5 212CDC5E5BBEDB65 215CF93874E36AB7
232C7F333BE67642 25DCC7C3844D420D 261D44624A364779 2B5EF5D9F0D15203 2BCEA922DFC09EB5 2DE165DBDD3ABBCA
2E094BA45D314144 33FDF4ADDF07245D 347E12F97D7A584A 34D7763EA7B96B20 357FA1CF0A7736E0 35B6240BB96E96B2
36267C7084A68023 37B58C8DBE67925C 3A24554FB6798AAE 3B28B7ABE767C78A 3B4B274A7B2A23A7 3C1EA3B9DA9F39A4
3E6022BC846F3A5A 3F1EB724A5767D4E 402F1810EFB14655 40744293B1B04CB2 415312F817C3B501 430C93DF34198D0E
43E4786F2CB61E00 475E1886CE3D8B71 491A682F95429D9B 4954746C70122F4A 4A0441CEA69711DF 4ACC45BBECF16E05
4BD9D9DD68C6D90B 4C832D32ED728A4C 4FE19E6996034931 5066ED788A811A1E 5361E2C1737BDC5D 53BC831ECE9BD052
53D04E2DA589206E 560F96692C5D1972 56620832F8471C43 56DFF2A5E255095D 588E334EFC232C6E 5B5B6007A7FE0C09
5B9F925876D7CDBF 5CB55CA026581C7B 5D93B70F650D9F25 5E1047352AE49652 5FA72055C20B59F0 6416CF204A9CEB61
677D2B56AE37729E 68519F218ACE2E54 6C8FCAB663306898 6D17D54BA8CCC7DB 6D65783347FD1F28 6EAC8450CB08665A
6EB4B6A46F576AA6 70663461CCD27837 722E129C54F80AD6 73C342B180A3421F 76B0BB1EC9DE3C59 76E8F2273F86FBE2
7B8B76C13E970DDA 7EFF18C667FD38DA 7FF471F6C059F4F6 811F549C9E34B4BC 82D2E14F8CD4E001 8579A26BA5F8E1BB
864C228CE0B556EB 8917383B089329B4 8B0B1A9F0D9D4E30 8EDAC1CC055F04F8 8FB8ECAE43A1348E 900F55BB9EEDD9AA
9110648925265158 9173A009F7D638FA 96106C9AA0E382F0 9B4C7C4F0E4D8F76 9B699F6BDFC16CEA 9BB2E9F1F9BA4913
9E5CAB98483F0AAD 9FB46AA47F4ADE7F A0AD07961802BBF2 A20FF18C95A4D735 A4596A8E4C262866 A521E76C6008BFCD
A7D70D7E096F79B9 A96D5A3B0D793949 AA4724CEAA0EC4E9 AB60634297B86147 AC8C9A7888B338EA AEC8453D71200BF3
B2CD705D65A29606 B5D86C7B3019ACDC B63308322B071913 B83D07321485CA07 B8AE63D66FA97E7C B9EBB936A4454A61
BADECD914A731181 BCC260391F9805F8 BD1603065B342219 BD3C760DFBC0FB20 BF9A4560FDFFA1E4 C23F5FA4DB01F02E
C38C86673FABB102 C84DF75A09B8B10E CA8CD85660F84E62 CAA420FE709542C9 CD2C125C32D8DE58 CE251A3EBD1B7D71
D132C286586E8869 D142C7480464122D D2CCEB37A9CF25C6 D2DD539B82018A1A D3F968753D880082 D419733A17302F6B
D606912270CB0184 D6BF55A039A28504 D78559369B94A0D4 DC2D3422B91ABFEE DCDBDF5C372E36D1 DE905A8496C09AB6
E14E08CA64B8D3F7 E2A018DB663FFA34 E59E03D3698AD106 EBBE56A29CF2DFF1 ED5BA5D8EF1EA281 EE1AAEE659E885F1
EEAFE831F6611D96 EEB515CCA0417032 F3B2284349F26C49 F46C35AD9B5F5469 F975F404FFEA03F3 FB4E738BAF50152E
FB5EAD5A16C2735F FC6F04BE90805A68 FC8B2343F15BB2F6
]])

local function finite(value)
    return type(value) == "number" and value == value and
        value > -math.huge and value < math.huge
end

function M.new(color, labels)
    return {
        labels = labels or ActorLabels.new(nil, HISTORY),
        total = 0, hits = 0, crits = 0, zero_hits = 0,
        interrupts = 0, cc_observations = 0, effect_events = 0,
        invalid_damage = 0, untimed = 0, limited = false,
        sources = {}, source_count = 0, source_color = color,
        abilities = {}, ability_count = 0, source_rows = nil, ability_rows = nil,
        events = {}, head = 0, count = 0, written = 0, overwritten = 0,
        buckets = {}, newest_bucket = nil, revision = 0,
    }
end

local function append(state, event, kind, name, source, amount, observed)
    state.head = state.head % HISTORY + 1
    local row = state.events[state.head]
    if not row then row = {}; state.events[state.head] = row end
    state.written = state.written + 1
    if state.count < HISTORY then state.count = state.count + 1
    else state.overwritten = state.overwritten + 1 end
    row.sequence, row.kind, row.action = state.written, kind, event.action
    row.timestamp = finite(event.timestamp) and event.timestamp or nil
    row.name, row.source, row.source_handle = name, source, event.source_handle
    row.actor_epoch = event.actor_epoch
    row.source_name, row.target_name = event.source_name, event.target_name
    if source and source.handle == event.source_handle then
        row.actor_label = source.actor_label
    else
        row.actor_label = state.labels:track(event.source_handle, event.actor_epoch, event.source_name)
    end
    row.ability_handle, row.effect_handle = event.ability_handle, event.effect_handle
    row.amount, row.critical, row.result = amount, event.critical == true, event.result
    row.target_handle, row.damage_type = event.target_handle, event.damage_type
    row.definition_key, row.category = nil, nil
    row.observed = observed == true
    state.revision = state.revision + 1
    if not row.timestamp then state.untimed = state.untimed + 1 end
    return row
end

local function add_bucket(state, timestamp, kind, amount)
    if not finite(timestamp) then return end
    local key = math.floor(timestamp / BUCKET_MS)
    if state.newest_bucket and key < state.newest_bucket - BUCKETS + 1 then return end
    state.newest_bucket = math.max(state.newest_bucket or key, key)
    local index = key % BUCKETS + 1
    local row = state.buckets[index]
    if not row then row = {}; state.buckets[index] = row end
    if row.key ~= key then
        row.key, row.damage, row.cc, row.interrupts = key, 0, 0, 0
    end
    if kind == "damage" then row.damage = row.damage + amount
    elseif kind == "cc" then row.cc = row.cc + 1
    elseif kind == "interrupt" then row.interrupts = row.interrupts + 1 end
end

function M.bucket(state, key)
    local row = state.buckets[key % BUCKETS + 1]
    return row and row.key == key and row or nil
end

local function source_row(state, event)
    local handle = event.source_handle
    local key = type(handle) == "string" and handle or "source:unknown"
    local row = state.sources[key]
    if not row then
        if state.source_count >= MAX_SOURCES - 1 then
            key = "source:other"
            row = state.sources[key]
            state.limited = true
        end
        if not row then
            row = {
                handle = key, name = key == "source:other" and "Other sources (limit)" or nil,
                name_placeholder = "Unresolved source",
                color = state.source_color, damage = 0, hits = 0, crits = 0,
                abilities = {}, ability_count = 0,
            }
            state.sources[key] = row
            state.source_count = state.source_count + 1
        end
    end
    if key ~= "source:other" then
        row.actor_label = state.labels:track(handle, event.actor_epoch, event.source_name)
    end
    return row
end

local function ability_row(owner, key, name, limit, state)
    local row = owner.abilities[key]
    if not row then
        if owner.ability_count >= limit - 1 then
            key, name = "ability:other", "Other abilities (limit)"
            row = owner.abilities[key]
            state.limited = true
        end
        if not row then
            row = { key = key, name = name, total = 0, hits = 0, crits = 0 }
            owner.abilities[key] = row
            owner.ability_count = owner.ability_count + 1
        end
    elseif row.name == "Unknown ability" and name ~= "Unknown ability" then
        row.name = name
    end
    return row
end

function M.is_incoming(event, player)
    if type(player) ~= "string" then return false end
    if event.kind == "damage" then return event.target_handle == player end
    -- AbilityInterrupt's source is the interrupted caster; its target may be absent.
    return event.kind == "ability" and event.action == "ability_interrupt" and
        event.source_handle == player
end

function M.consume(state, event, player)
    if type(player) ~= "string" then return end
    if event.kind == "damage" and event.target_handle == player then
        local amount = event.effective_amount
        if not finite(amount) or amount < 0 then
            state.invalid_damage = state.invalid_damage + 1
            append(state, event, "damage", event.name or "Unknown ability", nil, nil)
            return
        end
        local source = source_row(state, event)
        local name = type(event.name) == "string" and event.name ~= "" and event.name or "Unknown ability"
        local key = event.ability_handle or ("name:" .. name)
        state.total, state.hits = state.total + amount, state.hits + 1
        source.damage, source.hits = source.damage + amount, source.hits + 1
        if amount == 0 then state.zero_hits = state.zero_hits + 1 end
        local all = ability_row(state, key, name, MAX_ABILITIES, state)
        local own = ability_row(source, key, name, MAX_SOURCE_ABILITIES, state)
        all.total, all.hits = all.total + amount, all.hits + 1
        own.total, own.hits = own.total + amount, own.hits + 1
        if event.critical == true then
            state.crits, source.crits = state.crits + 1, source.crits + 1
            all.crits, own.crits = all.crits + 1, own.crits + 1
        end
        state.source_rows, state.ability_rows, source.ability_rows = nil, nil, nil
        append(state, event, "damage", name, source, amount)
        add_bucket(state, event.timestamp, "damage", amount)
    elseif event.kind == "ability" and event.action == "ability_interrupt" and event.source_handle == player then
        state.interrupts = state.interrupts + 1
        append(state, event, "interrupt", event.name or "Unknown interrupted ability", nil)
        add_bucket(state, event.timestamp, "interrupt", 0)
    elseif event.kind == "effect" and event.target_handle == player and
            (event.action == "add_effect" or event.action == "remove_effect") then
        state.effect_events = state.effect_events + 1
        local source = source_row(state, event)
        -- Do not label an unnamed effect using its causing ability or a nearby snapshot.
        append(state, event, "effect", event.action == "add_effect" and "Effect added" or "Effect removed", source)
    elseif event.kind == "death" and event.target_handle == player then
        append(state, event, "death", "You died", nil)
    end
end

local function row_name(row)
    return ActorLabels.text(row.actor_label, row.name or row.name_placeholder)
end

local function greater(left, right)
    local a, b = left.damage or left.total, right.damage or right.total
    if a ~= b then return a > b end
    local an, bn = row_name(left), row_name(right)
    if an ~= bn then return an < bn end
    return (left.handle or left.key) < (right.handle or right.key)
end

function M.sources(state)
    if not state.source_rows or state.source_name_revision ~= state.labels.version then
        state.source_name_revision = state.labels.version
        local rows = {}
        for _, row in pairs(state.sources) do
            if row.hits > 0 then rows[#rows + 1] = row end
        end
        table.sort(rows, greater)
        state.source_rows = rows
    end
    return state.source_rows
end

function M.abilities(state, handle)
    local owner = handle and state.sources[handle] or state
    if not owner then owner = state end
    if not owner.ability_rows then
        local rows = {}
        for _, row in pairs(owner.abilities) do rows[#rows + 1] = row end
        table.sort(rows, greater)
        owner.ability_rows = rows
    end
    return owner.ability_rows, owner.damage or owner.total, owner ~= state and row_name(owner) or nil
end

function M.new_cc_tracker()
    return { active = {}, generation = 0, status = "not sampled", missing_keys = 0, unknown = 0 }
end

function M.sample_cc(tracker, player, now)
    if not player then tracker.status = "player unavailable"; return nil end
    if type(player.effects) ~= "function" then tracker.status = "effects unavailable"; return nil end
    local observation = player:effects({ kind = "debuff" })
    if type(observation) ~= "table" or observation.status ~= "ready" then
        tracker.status = "pending / unavailable"
        return nil -- No removals inferred from a pending/absent observation.
    end
    local items = observation.items or {}
    if observation.truncated or #items > MAX_EFFECTS then
        tracker.status = "truncated"
        return nil
    end
    tracker.generation = tracker.generation + 1
    tracker.status, tracker.missing_keys, tracker.unknown = "sampled", 0, 0
    local changes
    for index = 1, #items do
        local effect = items[index]
        local key = effect.definition_key
        if type(key) ~= "string" or #key ~= 26 or not key:match("^effectdef:%x+$") then key = nil end
        local kind = key and CC[key] or nil
        if not key then tracker.missing_keys = tracker.missing_keys + 1
        elseif not kind then tracker.unknown = tracker.unknown + 1 end
        if kind then
            local seen = tracker.active[key]
            if not seen then
                local name = type(effect.name) == "string" and effect.name ~= "" and effect.name or kind
                seen = { name = name, category = kind }
                tracker.active[key] = seen
                changes = changes or {}
                changes[#changes + 1] = { action = "cc_observed", name = name, category = kind,
                    definition_key = key, timestamp = now }
            end
            seen.generation = tracker.generation
        end
    end
    if tracker.missing_keys > 0 then tracker.status = "missing effect identities" end
    -- Missing identity means we cannot prove any old definition disappeared.
    if tracker.missing_keys == 0 then
        for key, seen in pairs(tracker.active) do
            if seen.generation ~= tracker.generation then
                changes = changes or {}
                changes[#changes + 1] = { action = "cc_no_longer_observed", name = seen.name,
                    category = seen.category, definition_key = key, timestamp = now }
                tracker.active[key] = nil
            end
        end
    end
    return changes
end

function M.record_cc(state, observation)
    local row = append(state, observation, "cc", observation.name, nil, nil, true)
    row.definition_key, row.category = observation.definition_key, observation.category
    if observation.action == "cc_observed" then
        state.cc_observations = state.cc_observations + 1
        add_bucket(state, observation.timestamp, "cc", 0)
    end
end

M.filters = { "pressure", "damage", "cc", "interrupt", "effect", "all" }
M.filter_labels = { pressure = "Damage / CC / Int", damage = "Damage", cc = "CC observed",
    interrupt = "Interrupts", effect = "Effect lifecycle", all = "All events" }

function M.page(state, filter, page, limit, now)
    local cache = state.page_cache
    if cache and cache.filter == filter and cache.requested_page == page and
        (cache.revision == state.revision or now < cache.next_ms) then
        return cache.rows, cache.total, cache.page
    end
    cache = cache or { rows = {} }
    local total, start = 0, page * limit
    local selected = {}
    for offset = 0, state.count - 1 do
        local row = state.events[(state.head - 1 - offset) % HISTORY + 1]
        if filter == "all" or row.kind == filter or (filter == "pressure" and row.kind ~= "effect") then
            if total >= start and #selected < limit then selected[#selected + 1] = row end
            total = total + 1
        end
    end
    local actual_page = math.min(page, math.max(0, math.ceil(total / limit) - 1))
    if actual_page ~= page then return M.page(state, filter, actual_page, limit, now) end
    -- Copy only the seven visible records: ring slots can be reused while this
    -- 100 ms presentation cache lives. Never retain a mutable slot as a view.
    for index, row in ipairs(selected) do
        local copy = cache.rows[index] or {}
        for key in pairs(copy) do copy[key] = nil end
        for key, value in pairs(row) do copy[key] = value end
        cache.rows[index] = copy
    end
    for index = #cache.rows, #selected + 1, -1 do cache.rows[index] = nil end
    cache.filter, cache.requested_page, cache.page = filter, page, actual_page
    cache.total, cache.revision, cache.next_ms = total, state.revision, now + 100
    state.page_cache = cache
    return cache.rows, total, actual_page
end

return M
