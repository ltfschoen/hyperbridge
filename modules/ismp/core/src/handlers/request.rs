// Copyright (C) Polytope Labs Ltd.
// SPDX-License-Identifier: Apache-2.0

// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// 	http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

//! The ISMP request handler

use crate::{
    error::Error,
    handlers::{validate_state_machine, MessageResult},
    host::{IsmpHost, StateMachine},
    messaging::RequestMessage,
    module::{DispatchError, DispatchSuccess},
    router::{Request, RequestResponse},
};
use alloc::{format, vec::Vec};

/// Validate the state machine, verify the request message and dispatch the message to the modules
pub fn handle<H>(host: &H, msg: RequestMessage) -> Result<MessageResult, Error>
where
    H: IsmpHost,
{
    let state_machine = validate_state_machine(host, msg.proof.height)?;

    // Verify membership proof
    let state = host.state_machine_commitment(msg.proof.height)?;
    state_machine.verify_membership(
        host,
        RequestResponse::Request(msg.requests.clone().into_iter().map(Request::Post).collect()),
        state,
        &msg.proof,
    )?;

    let consensus_clients = host.consensus_clients();
    let check_for_consensus_client = |state_machine: StateMachine| {
        consensus_clients
            .iter()
            .find_map(|client| client.state_machine(state_machine).ok())
            .is_none()
    };

    let router = host.ismp_router();

    let result = msg
        .requests
        .into_iter()
        .map(|req| {
            let req_ = Request::Post(req.clone());

            // Validate request
            if host.request_receipt(&req_).is_none() && 
            !req_.timed_out(host.timestamp()) &&
            (req_.dest_chain() == host.host_state_machine() || 
            host.is_router()) &&
            (req_.source_chain() == msg.proof.height.id.state_id || 
            (host.is_allowed_proxy(&msg.proof.height.id.state_id) && check_for_consensus_client(req_.source_chain())))
            {
                Ok(req)
            } else {
                Err(Error::ImplementationSpecific(String::from("Request: Request does not meet the required criteria")))
            }
        }).collect::<Result<Vec<_>, Error>>()?;

        let result = result
            .into_iter()
            .map(|request| {
            let lambda = || {
                let cb = router.module_for_id(request.to.clone())?;
                let res = cb.on_accept(request.clone()).map(|_| DispatchSuccess {
                    dest_chain: request.dest,
                    source_chain: request.source,
                    nonce: request.nonce,
                });
                if res.is_ok() {
                    host.store_request_receipt(&Request::Post(request.clone()), &msg.signer)?;
                }
                Ok(res)
            };

            let res = lambda().and_then(|res| res).map_err(|e| DispatchError {
                msg: format!("{e:?}"),
                nonce: request.nonce,
                source_chain: request.source,
                dest_chain: request.dest,
            });
            res
        })
        .collect::<Vec<_>>();

    Ok(MessageResult::Request(result))
}
