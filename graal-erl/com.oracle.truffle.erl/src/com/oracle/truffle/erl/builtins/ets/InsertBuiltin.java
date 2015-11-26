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
package com.oracle.truffle.erl.builtins.ets;

import com.oracle.truffle.api.dsl.Specialization;
import com.oracle.truffle.api.nodes.NodeInfo;
import com.oracle.truffle.api.source.SourceSection;
import com.oracle.truffle.erl.MFA;
import com.oracle.truffle.erl.builtins.ErlBuiltinNode;
import com.oracle.truffle.erl.nodes.controlflow.ErlControlException;
import com.oracle.truffle.erl.runtime.ErlList;
import com.oracle.truffle.erl.runtime.ErlTuple;
import com.oracle.truffle.erl.runtime.ets.ErlTable;

/**
 * Inserts the object or all of the objects in the list ObjectOrObjects into the table Tab. If the
 * table is a set and the key of the inserted objects matches the key of any object in the table,
 * the old object will be replaced. If the table is an ordered_set and the key of the inserted
 * object compares equal to the key of any object in the table, the old object is also replaced. If
 * the list contains more than one object with matching keys and the table is a set, one will be
 * inserted, which one is not defined. The same thing holds for ordered_set, but will also happen if
 * the keys compare equal.
 * <p>
 * The entire operation is guaranteed to be atomic and isolated, even when a list of objects is
 * inserted.
 */
@NodeInfo(shortName = "insert")
public abstract class InsertBuiltin extends ErlBuiltinNode {

    public InsertBuiltin() {
        super(SourceSection.createUnavailable("Erlang ETS builtin", "insert"));
    }

    @Override
    public MFA getName() {
        return new MFA("ets", "insert", 2);
    }

    @Specialization
    public boolean insert(Object tid, ErlTuple tuple) {
        final ErlTable tab = ErlTable.findTable(tid);
        if (null != tab) {
            tab.insert(tuple);
            return true;
        }

        throw ErlControlException.makeBadarg();
    }

    @Specialization
    public boolean insert(Object tid, ErlList list) {
        final ErlTable tab = ErlTable.findTable(tid);
        if (null != tab) {
            tab.insert(list);
            return true;
        }

        throw ErlControlException.makeBadarg();
    }

    @Specialization
    public boolean insert(Object arg1, Object arg2) {

        if (arg2 instanceof ErlTuple) {
            return insert(arg1, (ErlTuple) arg2);
        }

        return insert(arg1, ErlList.fromObject(arg2));
    }
}
