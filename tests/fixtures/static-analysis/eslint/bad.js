var legacy = 1;
let neverReassigned = 2;
const unused = 42;

function check(a, b) {
    if (a == b) {
        return neverReassigned;
    }
    return legacy;
}

check(1, 2);
