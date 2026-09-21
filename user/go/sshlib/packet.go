package sshlib

const (
	pktLenField = 4
	pktBlock    = 8
	pktMinPad   = 4
	PktMaxTotal = 35000
)

type PktAlign int

const (
	AlignPlain PktAlign = iota
	AlignAEAD
)

func PaddingLen(payloadLen int, a PktAlign) int {
	base := 1 + payloadLen
	if a == AlignPlain {
		base = pktLenField + 1 + payloadLen
	}
	pad := pktBlock - (base % pktBlock)
	if pad < pktMinPad {
		pad += pktBlock
	}
	return pad
}

func PktAligned(packetLength uint32, a PktAlign) bool {
	pl := int(packetLength)
	if a == AlignPlain {
		return (pktLenField+pl)%pktBlock == 0
	}
	return pl%pktBlock == 0
}

func EncodePacket(payload, pad []byte, a PktAlign) ([]byte, bool) {
	min := PaddingLen(len(payload), a)
	if len(pad) < min || (len(pad)-min)%pktBlock != 0 {
		return nil, false
	}
	packetLength := 1 + len(payload) + len(pad)
	total := pktLenField + packetLength
	if total > PktMaxTotal {
		return nil, false
	}
	out := make([]byte, total)
	out[0] = byte(packetLength >> 24)
	out[1] = byte(packetLength >> 16)
	out[2] = byte(packetLength >> 8)
	out[3] = byte(packetLength)
	out[4] = byte(len(pad))
	copy(out[5:], payload)
	copy(out[5+len(payload):], pad)
	return out, true
}

func DecodePacket(frame []byte, a PktAlign) ([]byte, bool) {
	if len(frame) < 5 {
		return nil, false
	}
	packetLength := uint32(frame[0])<<24 | uint32(frame[1])<<16 | uint32(frame[2])<<8 | uint32(frame[3])
	padding := int(frame[4])
	pl := int(packetLength)
	if pl > PktMaxTotal-pktLenField || pl < 1+pktMinPad {
		return nil, false
	}
	if !PktAligned(packetLength, a) || padding < pktMinPad || padding > pl-1 {
		return nil, false
	}
	total := pktLenField + pl
	if len(frame) != total {
		return nil, false
	}
	payloadLen := pl - 1 - padding
	return frame[5 : 5+payloadLen], true
}
