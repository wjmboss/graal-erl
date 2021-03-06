/*
 * Copyright (c) 2012, 2014, Oracle and/or its affiliates. All rights reserved.
 * DO NOT ALTER OR REMOVE COPYRIGHT NOTICES OR THIS FILE HEADER.
 *
 * The Universal Permissive License (UPL), Version 1.0
 *
 * Subject to the condition set forth below, permission is hereby granted to any
 * person obtaining a copy of this software, associated documentation and/or
 * data (collectively the "Software"), free of charge and under any and all
 * copyright rights in the Software, and any and all patent rights owned or
 * freely licensable by each licensor hereunder covering either (i) the
 * unmodified Software as contributed to or provided by such licensor, or (ii)
 * the Larger Works (as defined below), to deal in both
 *
 * (a) the Software, and
 *
 * (b) any piece of software and/or hardware listed in the lrgrwrks.txt file if
 * one is included with the Software each a "Larger Work" to which the Software
 * is contributed by such licensors),
 *
 * without restriction, including without limitation the rights to copy, create
 * derivative works of, display, perform, and distribute the Software and make,
 * use, sell, offer for sale, import, export, have made, and have sold the
 * Software and the Larger Work(s), and to sublicense the foregoing rights on
 * either these or other terms.
 *
 * This license is subject to the following condition:
 *
 * The above copyright notice and either this complete permission notice or at a
 * minimum a reference to the UPL must be included in all copies or substantial
 * portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 */
package com.oracle.truffle.erl.nodes.expression;

import com.oracle.truffle.api.frame.VirtualFrame;
import com.oracle.truffle.api.nodes.NodeInfo;
import com.oracle.truffle.api.source.SourceSection;
import com.oracle.truffle.erl.nodes.ErlExpressionNode;
import com.oracle.truffle.erl.nodes.controlflow.ErlControlException;

@NodeInfo(shortName = "match", description = "The node that controls the matching mechanism.")
public final class ErlMatchNode extends ErlExpressionNode {

    @Child private ErlExpressionNode leftNode;
    @Child private ErlExpressionNode rightNode;

    public ErlMatchNode(SourceSection src, ErlExpressionNode leftNode, ErlExpressionNode rightNode) {
        super(src);
        this.leftNode = leftNode;
        this.rightNode = rightNode;

        assert null != leftNode;
        assert null != rightNode;
    }

    @Override
    public Object executeGeneric(VirtualFrame frame) {

        // This case covers the situation when an ErlMatchNode is a root of a match, and the caller
        // needs the matched value. The scheme is easy: get the value from the right-hand side, and
        // match it with the left-hand side.

        final Object rhs = rightNode.executeGeneric(frame);
        final Object lhs = leftNode.match(frame, rhs);
        if (null == lhs) {
            throw ErlControlException.makeBadmatch(rhs);
        }
        return lhs;
    }

    @Override
    public Object match(VirtualFrame frame, Object match) {

        // If a match() is called on an ErlMatchNode means it was called from an other ErlMatchNode.
        // In this case both leftNode and rightNode must be matched, and return the match value.

        if (null == leftNode.match(frame, match) || null == rightNode.match(frame, match)) {
            return null;
        }

        return match;
    }
}
