#!/usr/bin/env php
<?php
/**
 * Lightweight checks for provision edge MAC extract intent (mirrors mac-from-request.map).
 * Run: php tests/provision-edge/mac-from-request-test.php
 */

function extract_mac(string $uri, string $argMac = ''): string
{
    if (preg_match('/^([0-9A-Fa-f]{12})$/', $argMac, $m)) {
        $raw = $m[1];
    } else {
        $raw = '';
        if (preg_match('#^/provisioning/y000000#i', $uri) || preg_match('#y000000[0-9A-Fa-f]*\.cfg$#i', $uri)) {
            $raw = '';
        } elseif (preg_match('#_Security\.enc$#i', $uri) || preg_match('#\.boot$#i', $uri)) {
            $raw = '';
        } elseif (preg_match('#/cfg([0-9A-Fa-f]{12})\.xml$#i', $uri, $m)) {
            $raw = $m[1];
        } elseif (preg_match('#/([0-9A-Fa-f]{12})(?:-[A-Za-z0-9._]+)?\.(?:cfg|xml)$#i', $uri, $m)) {
            $raw = $m[1];
        } elseif (preg_match('#/([0-9A-Fa-f]{12})/?$#', $uri, $m)) {
            $raw = $m[1];
        }
    }
    if (preg_match('/^0{12}$/i', $raw)) {
        return '';
    }

    return $raw;
}

$cases = [
    ['/provisioning/aabbccddeeff.cfg', '', 'aabbccddeeff'],
    ['/provisioning/AABBCCDDEEFF.cfg', '', 'AABBCCDDEEFF'],
    ['/provisioning/aabbccddeeff-reg.cfg', '', 'aabbccddeeff'],
    ['/provisioning/aabbccddeeff-directory.xml', '', 'aabbccddeeff'],
    ['/provisioning/cfgaabbccddeeff.xml', '', 'aabbccddeeff'],
    ['/provisioning/foo.cfg', 'aabbccddeeff', 'aabbccddeeff'],
    ['/provisioning/y000000000028.cfg', '', ''],
    ['/provisioning/x_Security.enc', '', ''],
    ['/provisioning/phone.boot', '', ''],
    ['/provisioning/000000000000.cfg', '', ''],
    ['/aabbccddeeff.cfg', '', 'aabbccddeeff'],
];

$fail = 0;
foreach ($cases as [$uri, $arg, $want]) {
    $got = extract_mac($uri, $arg);
    if ($got !== $want) {
        fwrite(STDERR, "FAIL uri={$uri} arg={$arg} want={$want} got={$got}\n");
        $fail++;
    }
}

if ($fail > 0) {
    fwrite(STDERR, "{$fail} failure(s)\n");
    exit(1);
}
echo "OK (".count($cases)." cases)\n";
