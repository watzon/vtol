module tl

fn test_decode_mtproto_object_handles_rpc_result_and_gzip_packed() {
	pong := Pong{
		msg_id:  41
		ping_id: 99
	}
	result := RpcResult{
		req_msg_id: 77
		result:     GzipPacked{
			object: pong
		}
	}

	decoded := decode_mtproto_object(result.encode() or { panic(err) }) or { panic(err) }
	match decoded {
		RpcResult {
			assert decoded.req_msg_id == 77
			match decoded.result {
				GzipPacked {
					match decoded.result.object {
						Pong {
							assert decoded.result.object.msg_id == 41
							assert decoded.result.object.ping_id == 99
						}
						else {
							assert false
						}
					}
				}
				else {
					assert false
				}
			}
		}
		else {
			assert false
		}
	}
}
