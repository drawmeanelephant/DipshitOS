// SSH-2 server state machine (M70g G1, #1491): the ADR 0025 D2 profile with
// the roles reversed. Feed is a pure byte-stream step — production wraps it
// over vi.Conn; host tests drive a scripted client against it with no VM.

package main

const (
	msgDisconnect     byte = 1
	msgIgnore         byte = 2
	msgDebug          byte = 4
	msgServiceRequest byte = 5
	msgServiceAccept  byte = 6
	msgKexInit        byte = 20
	msgNewKeys        byte = 21
	msgKexECDHInit    byte = 30
	msgKexECDHReply   byte = 31
	msgUserauthReq    byte = 50
	msgUserauthFail   byte = 51
	msgUserauthOK     byte = 52
	msgChannelOpen    byte = 90
	msgChannelConfirm byte = 91
	msgChannelWindow  byte = 93
	msgChannelData    byte = 94
	msgChannelEOF     byte = 96
	msgChannelClose   byte = 97
	msgChannelReq     byte = 98
	msgChannelOK      byte = 99
	msgChannelFail    byte = 100

	algoEd25519   = "ssh-ed25519"
	kexCurve      = "curve25519-sha256"
	kexCurveAlias = "curve25519-sha256@libssh.org"
	cipherOpenSSH = "chacha20-poly1305@openssh.com"
	compNone      = "none"
	svcUserauth   = "ssh-userauth"
	svcConnection = "ssh-connection"
	methodNone    = "none"
	methodPubKey  = "publickey"
	chanSession   = "session"
	reqExec       = "exec"
	reqExitStatus = "exit-status"

	identLine = "SSH-2.0-VirelaiOS_1.0"

	localWindow    uint32 = 1 << 17
	localMaxPacket uint32 = 32768
	serverChanID   uint32 = 42
)

type phase int

const (
	phaseVersion phase = iota
	phaseKex
	phaseEncrypted
	phaseFailed
	phaseClosed
)

// AuthKey is one SSH/AUTHORIZED_KEYS row: a user name and a 32-byte
// ssh-ed25519 public key.
type AuthKey struct {
	User string
	Pub  [32]byte
}

// ExecFunc runs one remote command and returns its captured stdout and
// exit status. Production hands the line to GOSH.ELF -c; tests inject a
// fixed marker.
type ExecFunc func(cmd string) (stdout []byte, status uint32, err error)

// EntropyFunc fills b with random bytes.
type EntropyFunc func(b []byte) error

type serverConfig struct {
	hostSeed  [32]byte
	keys      []AuthKey
	run       ExecFunc
	log       func(string)
	entropy   EntropyFunc
	ident     string
	cookie    []byte // optional deterministic KEXINIT cookie
	ephemeral []byte // optional deterministic X25519 secret
}

type Server struct {
	cfg        serverConfig
	hostPub    [32]byte
	phase      phase
	input      []byte
	out        []byte
	banners    int
	clientVer  string
	iC, iS     []byte
	qC, qS     []byte
	sessionID  []byte
	sendCipher *sshCipher
	recvCipher *sshCipher
	sendSeq    uint64
	recvSeq    uint64
	clientChan uint32
	remoteWin  uint32
	remoteMax  uint32
	execRan    bool
	closed     bool
	failed     bool
}

func newServer(cfg serverConfig) *Server {
	if cfg.ident == "" {
		cfg.ident = identLine
	}
	if cfg.log == nil {
		cfg.log = func(string) {}
	}
	if cfg.entropy == nil {
		cfg.entropy = func(b []byte) error {
			for i := range b {
				b[i] = 0x5a
			}
			return nil
		}
	}
	return &Server{
		cfg:     cfg,
		hostPub: edDerivePublic(cfg.hostSeed),
		phase:   phaseVersion,
	}
}

func (s *Server) Closed() bool { return s.phase == phaseClosed || s.phase == phaseFailed }

func (s *Server) Failed() bool { return s.phase == phaseFailed }

func (s *Server) Feed(data []byte) []byte {
	if s.Closed() {
		return nil
	}
	s.input = append(s.input, data...)
	s.process()
	out := s.out
	s.out = nil
	return out
}

func (s *Server) process() {
	for !s.Closed() {
		switch s.phase {
		case phaseVersion:
			if !s.readVersion() {
				return
			}
		case phaseKex:
			payload, ok := s.nextPlain()
			if !ok {
				return
			}
			s.handleKex(payload)
		case phaseEncrypted:
			payload, ok := s.nextEncrypted()
			if !ok {
				return
			}
			s.handleEncrypted(payload)
		default:
			return
		}
	}
}

func (s *Server) readVersion() bool {
	for {
		nl := -1
		for i, b := range s.input {
			if b == 0x0a {
				nl = i
				break
			}
		}
		if nl < 0 {
			if len(s.input) > 255 {
				s.fail("version too long")
			}
			return false
		}
		raw := s.input[:nl]
		s.input = s.input[nl+1:]
		if len(raw) > 0 && raw[len(raw)-1] == 0x0d {
			raw = raw[:len(raw)-1]
		}
		if len(raw) < 4 || string(raw[:4]) != "SSH-" {
			s.banners++
			if s.banners > 64 {
				s.fail("too many banner lines")
				return false
			}
			continue
		}
		text := string(raw)
		if !(len(text) >= 8 && (text[:8] == "SSH-2.0-" || (len(text) >= 9 && text[:9] == "SSH-1.99-"))) {
			s.fail("bad identification line")
			return false
		}
		s.clientVer = text
		s.cfg.log("version received: " + text)
		s.out = append(s.out, []byte(s.cfg.ident+"\r\n")...)
		s.sendKexInit()
		s.phase = phaseKex
		return true
	}
}

func (s *Server) sendKexInit() {
	var w sshWriter
	w.byte(msgKexInit)
	cookie := s.cfg.cookie
	if len(cookie) != 16 {
		var c [16]byte
		_ = s.cfg.entropy(c[:])
		cookie = c[:]
	}
	w.raw(cookie)
	w.nameList([]string{kexCurve, kexCurveAlias})
	w.nameList([]string{algoEd25519})
	w.nameList([]string{cipherOpenSSH})
	w.nameList([]string{cipherOpenSSH})
	w.nameList(nil)
	w.nameList(nil)
	w.nameList([]string{compNone})
	w.nameList([]string{compNone})
	w.nameList(nil)
	w.nameList(nil)
	w.boolVal(false)
	w.u32(0)
	s.iS = append([]byte(nil), w.b...)
	s.sendPacket(s.iS)
	s.cfg.log("kexinit sent")
}

func (s *Server) nextPlain() ([]byte, bool) {
	if len(s.input) < 4 {
		return nil, false
	}
	packetLength := int(s.input[0])<<24 | int(s.input[1])<<16 | int(s.input[2])<<8 | int(s.input[3])
	if packetLength > pktMaxTotal-4 || packetLength < 5 {
		s.fail("bad plaintext length")
		return nil, false
	}
	total := 4 + packetLength
	if len(s.input) < total {
		return nil, false
	}
	frame := s.input[:total]
	s.input = s.input[total:]
	payload, ok := decodePacket(frame, alignPlain)
	if !ok {
		s.fail("malformed plaintext frame")
		return nil, false
	}
	s.recvSeq++
	return payload, true
}

func (s *Server) handleKex(payload []byte) {
	if len(payload) == 0 {
		s.fail("empty kex packet")
		return
	}
	switch payload[0] {
	case msgKexInit:
		if !s.parseClientKexInit(payload) {
			return
		}
		s.cfg.log("kexinit received (suite negotiated)")
	case msgKexECDHInit:
		r := sshReader{b: payload}
		if b, ok := r.byte(); !ok || b != msgKexECDHInit {
			s.fail("malformed KEX_ECDH_INIT")
			return
		}
		q, ok := r.str()
		if !ok || len(q) != 32 || r.remaining() != 0 {
			s.fail("malformed KEX_ECDH_INIT")
			return
		}
		s.qC = append([]byte(nil), q...)
		s.performKex()
	case msgNewKeys:
		if len(payload) != 1 {
			s.fail("malformed NEWKEYS")
			return
		}
		s.cfg.log("newkeys received; cipher installed")
		s.phase = phaseEncrypted
	case msgDisconnect:
		s.cfg.log("client disconnect during kex")
		s.phase = phaseClosed
	case msgIgnore, msgDebug:
	default:
		s.fail("unexpected kex message")
	}
}

func (s *Server) parseClientKexInit(payload []byte) bool {
	r := sshReader{b: payload}
	if b, ok := r.byte(); !ok || b != msgKexInit {
		return false
	}
	if r.remaining() < 16 {
		s.fail("short KEXINIT")
		return false
	}
	r.pos += 16
	kex, ok1 := r.nameList()
	host, ok2 := r.nameList()
	encC, ok3 := r.nameList()
	encS, ok4 := r.nameList()
	_, ok5 := r.nameList()
	_, ok6 := r.nameList()
	compC, ok7 := r.nameList()
	compS, ok8 := r.nameList()
	_, ok9 := r.nameList()
	_, ok10 := r.nameList()
	_, ok11 := r.boolVal()
	reserved, ok12 := r.u32()
	if !ok1 || !ok2 || !ok3 || !ok4 || !ok5 || !ok6 || !ok7 || !ok8 || !ok9 || !ok10 || !ok11 || !ok12 || r.remaining() != 0 || reserved != 0 {
		s.fail("malformed KEXINIT")
		return false
	}
	kexOK := containsName(kex, kexCurve) || containsName(kex, kexCurveAlias)
	hostOK := containsName(host, algoEd25519)
	cipherOK := containsName(encC, cipherOpenSSH) && containsName(encS, cipherOpenSSH)
	compOK := containsName(compC, compNone) && containsName(compS, compNone)
	if !kexOK || !hostOK || !cipherOK || !compOK {
		s.fail("no common algorithm")
		return false
	}
	s.iC = append([]byte(nil), payload...)
	return true
}

func (s *Server) performKex() {
	var eph [32]byte
	if len(s.cfg.ephemeral) == 32 {
		copy(eph[:], s.cfg.ephemeral)
	} else if err := s.cfg.entropy(eph[:]); err != nil {
		s.fail("entropy")
		return
	}
	qS, ok := x25519Base(eph)
	if !ok {
		s.fail("bad ephemeral secret")
		return
	}
	s.qS = qS[:]
	var qC [32]byte
	copy(qC[:], s.qC)
	kRaw, ok := x25519(eph, qC)
	wipe(eph[:])
	if !ok {
		s.fail("all-zero shared secret")
		return
	}
	kMpint := mpint(kRaw[:])
	wipe(kRaw[:])

	var ks sshWriter
	ks.strS(algoEd25519)
	ks.str(s.hostPub[:])
	kS := ks.b

	h := exchangeHash(
		[]byte(s.clientVer), []byte(s.cfg.ident),
		s.iC, s.iS, kS, s.qC, s.qS, kMpint,
	)
	sig := edSign(h[:], s.cfg.hostSeed)
	var sigBlob sshWriter
	sigBlob.strS(algoEd25519)
	sigBlob.str(sig[:])

	var reply sshWriter
	reply.byte(msgKexECDHReply)
	reply.str(kS)
	reply.str(s.qS)
	reply.str(sigBlob.b)
	s.sendPacket(reply.b)
	s.sendPacket([]byte{msgNewKeys})

	s.sessionID = h[:]
	keyC2S := deriveKey(sshCipherKey, kMpint, h[:], 'C', h[:])
	keyS2C := deriveKey(sshCipherKey, kMpint, h[:], 'D', h[:])
	var recv, send sshCipher
	copy(recv.key[:], keyC2S)
	copy(send.key[:], keyS2C)
	s.recvCipher = &recv
	s.sendCipher = &send
	wipe(keyC2S)
	wipe(keyS2C)
	s.cfg.log("ecdh reply sent; newkeys sent")
}

func (s *Server) nextEncrypted() ([]byte, bool) {
	if s.recvCipher == nil || len(s.input) < 4 {
		return nil, false
	}
	length := int(s.recvCipher.decryptLength(s.input[:4], s.recvSeq))
	if length < 5 || length > pktMaxTotal-4 {
		s.fail("bad encrypted length")
		return nil, false
	}
	ctLen := 4 + length
	wire := ctLen + polyTagLen
	if len(s.input) < wire {
		return nil, false
	}
	ct := s.input[:ctLen]
	tag := s.input[ctLen:wire]
	plain := s.recvCipher.open(ct, tag, s.recvSeq)
	if plain == nil {
		s.cfg.log("mac-failure — disconnecting")
		s.phase = phaseFailed
		return nil, false
	}
	s.input = s.input[wire:]
	s.recvSeq++
	payload, ok := decodePacket(plain, alignAEAD)
	if !ok {
		s.fail("malformed encrypted frame")
		return nil, false
	}
	return payload, true
}

func (s *Server) handleEncrypted(payload []byte) {
	if len(payload) == 0 {
		return
	}
	switch payload[0] {
	case msgIgnore, msgDebug:
	case msgDisconnect:
		s.cfg.log("client disconnect")
		s.phase = phaseClosed
	case msgServiceRequest:
		s.handleService(payload)
	case msgUserauthReq:
		s.handleUserauth(payload)
	case msgChannelOpen:
		s.handleChannelOpen(payload)
	case msgChannelReq:
		s.handleChannelReq(payload)
	case msgChannelWindow:
		r := sshReader{b: payload}
		_, _ = r.byte()
		_, _ = r.u32()
		if add, ok := r.u32(); ok {
			s.remoteWin += add
		}
	case msgChannelEOF, msgChannelClose:
		s.cfg.log("channel eof/close from client")
		s.phase = phaseClosed
	default:
		s.cfg.log("unhandled message")
	}
}

func (s *Server) handleService(payload []byte) {
	r := sshReader{b: payload}
	_, _ = r.byte()
	name, ok := r.strUTF8()
	if !ok || r.remaining() != 0 {
		s.fail("malformed service request")
		return
	}
	if name != svcUserauth {
		s.fail("unsupported service")
		return
	}
	var w sshWriter
	w.byte(msgServiceAccept)
	w.strS(svcUserauth)
	s.sendPacket(w.b)
	s.cfg.log("service-accept ssh-userauth")
}

func (s *Server) handleUserauth(payload []byte) {
	r := sshReader{b: payload}
	_, _ = r.byte()
	user, ok1 := r.strUTF8()
	service, ok2 := r.strUTF8()
	method, ok3 := r.strUTF8()
	if !ok1 || !ok2 || !ok3 {
		s.fail("malformed userauth request")
		return
	}
	if method == methodNone {
		s.cfg.log("userauth none requested; offering publickey")
		s.sendUserauthFail()
		return
	}
	if method != methodPubKey || service != svcConnection {
		s.fail("unsupported userauth method")
		return
	}
	hasSig, ok := r.boolVal()
	algo, okA := r.strUTF8()
	keyBlob, okB := r.str()
	if !ok || !okA || !okB {
		s.fail("malformed publickey request")
		return
	}
	sigOffset := r.pos
	pub, okPub := parseEd25519Blob(keyBlob)
	if !okPub || algo != algoEd25519 || !s.keyAllowed(user, pub) {
		s.cfg.log("publickey rejected: key does not match AUTHORIZED_KEYS")
		s.sendUserauthFail()
		return
	}
	if !hasSig {
		s.cfg.log("publickey rejected: no signature")
		s.sendUserauthFail()
		return
	}
	sigBlob, ok := r.str()
	if !ok || r.remaining() != 0 {
		s.fail("malformed publickey signature")
		return
	}
	sr := sshReader{b: sigBlob}
	sigAlg, okS := sr.strUTF8()
	sigBytes, okT := sr.str()
	if !okS || !okT || sr.remaining() != 0 || sigAlg != algoEd25519 || len(sigBytes) != 64 {
		s.cfg.log("publickey rejected: malformed signature blob")
		s.sendUserauthFail()
		return
	}
	var signed sshWriter
	signed.str(s.sessionID)
	signed.raw(payload[:sigOffset])
	var sig [64]byte
	copy(sig[:], sigBytes)
	if !edVerify(sig, signed.b, pub) {
		s.cfg.log("publickey rejected: signature does not verify")
		s.sendUserauthFail()
		return
	}
	s.sendPacket([]byte{msgUserauthOK})
	s.cfg.log("publickey accepted user=" + user + " key=ssh-ed25519")
}

func parseEd25519Blob(blob []byte) ([32]byte, bool) {
	var zero [32]byte
	r := sshReader{b: blob}
	name, ok := r.strUTF8()
	key, ok2 := r.str()
	if !ok || !ok2 || r.remaining() != 0 || name != algoEd25519 || len(key) != 32 {
		return zero, false
	}
	var pub [32]byte
	copy(pub[:], key)
	return pub, true
}

func (s *Server) keyAllowed(user string, pub [32]byte) bool {
	for _, k := range s.cfg.keys {
		if k.Pub != pub {
			continue
		}
		if k.User == "" || k.User == user {
			return true
		}
	}
	return false
}

func (s *Server) sendUserauthFail() {
	var w sshWriter
	w.byte(msgUserauthFail)
	w.nameList([]string{methodPubKey})
	w.boolVal(false)
	s.sendPacket(w.b)
}

func (s *Server) handleChannelOpen(payload []byte) {
	r := sshReader{b: payload}
	_, _ = r.byte()
	typ, ok1 := r.strUTF8()
	sender, ok2 := r.u32()
	window, ok3 := r.u32()
	maxPkt, ok4 := r.u32()
	if !ok1 || !ok2 || !ok3 || !ok4 || r.remaining() != 0 {
		s.fail("malformed channel open")
		return
	}
	if typ != chanSession || maxPkt == 0 {
		s.fail("unsupported channel type")
		return
	}
	s.clientChan = sender
	s.remoteWin = window
	s.remoteMax = maxPkt
	var w sshWriter
	w.byte(msgChannelConfirm)
	w.u32(sender)
	w.u32(serverChanID)
	w.u32(localWindow)
	w.u32(localMaxPacket)
	s.sendPacket(w.b)
	s.cfg.log("channel open session confirmed")
}

func (s *Server) handleChannelReq(payload []byte) {
	r := sshReader{b: payload}
	_, _ = r.byte()
	recip, ok1 := r.u32()
	req, ok2 := r.strUTF8()
	want, ok3 := r.boolVal()
	if !ok1 || !ok2 || !ok3 || recip != serverChanID {
		s.fail("malformed channel request")
		return
	}
	if req == reqExec {
		cmd, ok := r.strUTF8()
		if !ok || r.remaining() != 0 {
			s.fail("malformed exec request")
			return
		}
		if s.execRan {
			s.fail("second exec request")
			return
		}
		s.execRan = true
		if want {
			var w sshWriter
			w.byte(msgChannelOK)
			w.u32(s.clientChan)
			s.sendPacket(w.b)
		}
		s.cfg.log("exec " + cmd)
		stdout := []byte(nil)
		status := uint32(1)
		if s.cfg.run != nil {
			out, st, err := s.cfg.run(cmd)
			if err == nil {
				stdout = out
				status = st
			}
		}
		s.sendChannelData(stdout)
		s.sendExitStatus(status)
		s.sendPacket(s.channelHeader(msgChannelEOF))
		s.sendPacket(s.channelHeader(msgChannelClose))
		s.cfg.log("exec done")
		s.phase = phaseClosed
		return
	}
	if want {
		var w sshWriter
		w.byte(msgChannelFail)
		w.u32(s.clientChan)
		s.sendPacket(w.b)
	}
	s.cfg.log("channel request refused")
}

func (s *Server) channelHeader(kind byte) []byte {
	var w sshWriter
	w.byte(kind)
	w.u32(s.clientChan)
	return w.b
}

func (s *Server) sendChannelData(data []byte) {
	off := 0
	for off < len(data) {
		room := int(s.remoteWin)
		if int(s.remoteMax) < room {
			room = int(s.remoteMax)
		}
		if room > 32768 {
			room = 32768
		}
		if room > len(data)-off {
			room = len(data) - off
		}
		if room <= 0 {
			break
		}
		var w sshWriter
		w.byte(msgChannelData)
		w.u32(s.clientChan)
		w.str(data[off : off+room])
		s.sendPacket(w.b)
		s.remoteWin -= uint32(room)
		off += room
	}
}

func (s *Server) sendExitStatus(status uint32) {
	var w sshWriter
	w.byte(msgChannelReq)
	w.u32(s.clientChan)
	w.strS(reqExitStatus)
	w.boolVal(false)
	w.u32(status)
	s.sendPacket(w.b)
}

func (s *Server) sendPacket(payload []byte) {
	align := alignPlain
	if s.sendCipher != nil {
		align = alignAEAD
	}
	pad := make([]byte, paddingLen(len(payload), align))
	_ = s.cfg.entropy(pad)
	frame, ok := encodePacket(payload, pad, align)
	if !ok {
		s.fail("could not frame outbound packet")
		return
	}
	if s.sendCipher != nil {
		ct, tag := s.sendCipher.seal(frame, s.sendSeq)
		s.out = append(s.out, ct...)
		s.out = append(s.out, tag...)
	} else {
		s.out = append(s.out, frame...)
	}
	s.sendSeq++
}

func (s *Server) fail(reason string) {
	s.cfg.log("protocol failure: " + reason)
	s.phase = phaseFailed
}
