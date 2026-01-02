wrk.method = "POST"
wrk.headers["Content-Type"] = "application/json"

-- 여기에 실제 검색할 벡터 데이터를 JSON 문자열로 넣으세요.
-- 예시: 768차원 벡터
local vector_data = {}
for i=1,768 do
    table.insert(vector_data, 0.1)
end

local vector_json = "[" .. table.concat(vector_data, ",") .. "]"

wrk.body = '{"vector": ' .. vector_json .. ', "k": 10}'

function setup(thread)
    thread:set("timeout", 5000)  -- 밀리초 단위 (5000ms = 5초)
end