/**************************************************************
	FPGA New Rally-X (Main part)
***************************************************************/
module fpga_NRX
(
	input				RESET,		// RESET
	input				CLK24M,		// Clock 24.576MHz

	input	  [3:0]	GAME,			// Game select (0=RallyX,1=NewRallyX,2=Jungler,3=Tactician,4=LocoMotion,5=Commando)

	input	  [8:0]	HP,			// VIDEO H-POSITION input
	input   [8:0]	VP,			// VIDEO V-POSITION input
	output			PCLK,			// PIXEL Clock output
	output  [7:0]	POUT,			// PIXEL Color output

	output  [7:0]	SND,			// Sound (unsigned PCM)

	input   [7:0]	DSW,			// DipSW  (Namco DSW / Konami DSW1)
	input   [7:0]	DSW2,			// Konami DSW2 (Loco-Motion hardware only)
	input	  [7:0]	CTR1,			// Controler (Negative logic)  (Konami: P1)
	input	  [7:0]	CTR2,			//                             (Konami: P2)

	output  [1:0]	LAMP,			// Lamp output

	input				ROMCL,		// Downloaded ROM image
	input  [15:0] 	ROMAD,
	input	  [7:0]	ROMDT,
	input				ROMEN,

	input				pause,

	input	 [15:0]	hs_address,
	input	 [7:0]	hs_data_in,
	output [7:0]	hs_data_out,
	input				hs_write,
	input				hs_access
);


//--------------------------------------------------
//  Clock Generators
//--------------------------------------------------
reg [2:0] _CCLK;
always @( posedge CLK24M ) _CCLK <= _CCLK+1;

wire	CLK    = CLK24M;		// 24MHz
wire	CCLKx2 = _CCLK[1];	// CPU CLOCKx2 : 6.0MHz
wire	CCLK   = _CCLK[2];	// CPU CLOCK   : 3.0MHz


//--------------------------------------------------
//  CPU
//--------------------------------------------------
// memory access signals
wire			rd, wr, me, ie, rf, m1;
wire [15:0] ad;
wire [7:0]  odt, viddata;

wire			mx      = rf & (~me);
wire			mr		  = mx & (~rd);
wire			mw      = mx & (~wr);

// Hardware family: Namco Rally-X (GAME 0/1) vs Konami Loco-Motion (GAME >= 2)
wire			is_konami = ( GAME >= 4'd2 );

// interrupt signal/vector generator & other latches
reg			inte  = 1'b0;	// Namco: IRQ enable / Konami: NMI enable (INTST)
reg			intl  = 1'b0;	// VBLANK interrupt-pending flip-flop
reg  [7:0]	intv  = 8'h0;	// Namco IM2 interrupt vector (no Konami equivalent)

reg			bang  = 1'b0;	// Namco explosion "BANG"

reg			lp0r  = 1'b0;	// Namco lamp0 / Konami coin counter 1 (OUT1)
reg			lp1r  = 1'b0;	// Namco lamp1 / Konami coin counter 2 (OUT3)
assign		LAMP  = { lp1r, lp0r };

// Konami Loco-Motion LS259 control outputs
reg			soundon = 1'b0;	// Q0 SOUNDON  (sound-CPU IRQ trigger, consumed in Phase 3)
reg			sndmute = 1'b0;	// Q2 MUT
reg			flipscr = 1'b0;	// Q3 FLIP
reg			starson = 1'b0;	// Q7 STARSON  (starfield enable, consumed in Phase 2)
reg  [7:0]	sndlatch = 8'h0;	// command to sound CPU, written at $A100 (consumed in Phase 3)

wire			vblk  = (VP==224)&(HP<=8);

wire			lat_Wce = ( ad[15:4] == 12'hA18 ) & mw;	// $A180-$A18F latch block

// Namco latch decodes
wire			bngw = ( lat_Wce & ( ad[3:0] == 4'h0 ) );
wire			iewr = ( lat_Wce & ( ad[3:0] == 4'h1 ) );
wire			flip = ( lat_Wce & ( ad[3:0] == 4'h3 ) );
wire			lp0w = ( lat_Wce & ( ad[3:0] == 4'h4 ) );
wire			lp1w = ( lat_Wce & ( ad[3:0] == 4'h5 ) );
wire			iowr = ( (~wr) & (~ie) & m1 );

// Konami sound-command write at $A100-$A11F (separate from the $A18x latch block)
wire			konami_sndw = is_konami & mw & ( ad[15:8] == 8'hA1 ) & ( ad[7:5] == 3'b000 );

always @( posedge CCLK ) begin
	if ( is_konami ) begin
		// LS259 addressable latch at $A180-$A187, serial data = odt[0]
		if ( lat_Wce ) case ( ad[2:0] )
			3'd0: soundon <= odt[0];	// SOUNDON
			3'd1: inte    <= odt[0];	// INTST (NMI mask)
			3'd2: sndmute <= odt[0];	// MUT
			3'd3: flipscr <= odt[0];	// FLIP
			3'd4: lp0r    <= odt[0];	// OUT1 coin counter 1
			3'd6: lp1r    <= odt[0];	// OUT3 coin counter 2
			3'd7: starson <= odt[0];	// STARSON
			default: ;
		endcase
		// VBLANK sets the NMI-pending flip-flop; the NMI handler clears it
		// by writing INTST (Q1) low (matches MAME nmi_mask_w semantics).
		if ( vblk ) intl <= 1'b1;
		if ( lat_Wce & ( ad[2:0] == 3'd1 ) & (~odt[0]) ) intl <= 1'b0;
		if ( konami_sndw ) sndlatch <= odt;
	end
	else begin
		// Namco Rally-X behaviour (unchanged)
		if ( iowr ) intv <= odt;
		if ( vblk ) intl <= 1'b1;
		if ( iewr ) begin
			inte <= odt[0];
			intl <= 1'b0;
		end
		if ( bngw ) bang <= odt[0];
		if ( lp0w ) lp0r <= odt[0];
		if ( lp1w ) lp1r <= odt[0];
	end
end

// Namco: maskable IRQ (active when pending & enabled).  Konami: VBLANK NMI.
wire	irq_n = is_konami ? 1'b1            : ~( intl & inte );
wire	nmi_n = is_konami ? ~( intl & inte ) : 1'b1;


// address decoders
//   Program ROM: Namco $0000-$3FFF (16K), Konami $0000-$7FFF (32K)
wire	rom_Rce = ( is_konami ? ( ad[15] == 1'b0 ) : ( ad[15:14] == 2'b00 ) ) & mr;
wire	ram_Rce = ( ( ad[15:11] == 5'b1001_1    ) & mr );		// $9800-$9FFF(R)
wire	ram_Wce = ( ( ad[15:11] == 5'b1001_1    ) & mw );		// $9800-$9FFF(W)
wire	inp_Rce = ( ( ad[15:12] == 4'b1010      ) & mr );		// $A000-$AFFF(R)
wire	snd_Wce = ( ( ad[15:8]  == 8'b1010_0001 ) & mw );		// $A100-$A1FF(W) Namco WSG
wire	vid_Rce;


// Unified 32K program ROM. The download gate (ROMAD[15]==0) captures the program
// for both families; for Namco the graphics regions ($4xxx-$53xx) also alias into
// the unused upper half but are never read (rom_Rce masks to the low 16K).
wire  [7:0]	romdata;
DLROM #(15,8) cpurom(CCLK,ad[14:0],romdata, ROMCL,ROMAD,ROMDT,ROMEN & (ROMAD[15]==1'b0));

// Work RAM (2KB)
wire [7:0] ramdata;
GSPRAM #(11,8) workram( CCLK, ad[10:0], ram_Wce, odt, ramdata );


// Controler/DipSW input
//   Namco : $A000=in0, $A080=in1, $A1xx=DSW
//   Konami: $A000=P1,  $A080=P2,  $A100=DSW1, $A180=DSW2
wire [7:0]  in0data = CTR1;
wire [7:0]  in1data = CTR2;
wire [7:0]  in2data = DSW;
wire [7:0]  in3data = DSW2;
wire [7:0]  namco_inp  = ad[8] ? in2data : ad[7] ? in1data : in0data;
wire [7:0]  konami_inp = ad[8] ? ( ad[7] ? in3data : in2data )
                               : ( ad[7] ? in1data : in0data );
wire [7:0]  inpdata = is_konami ? konami_inp : namco_inp;


// databus selector
wire [7:0]	romd  = rom_Rce ? romdata : 8'h00;
wire [7:0]  ramd  = ram_Rce ? ramdata : 8'h00;
wire [7:0]  vidd  = vid_Rce ? viddata : 8'h00;
wire [7:0]	inpd  = inp_Rce ? inpdata : 8'h00;
// Namco IM2 interrupt-vector fetch; Konami uses fixed NMI vector (no bus drive).
wire [7:0]	irqv  = ( (~m1) & (~ie) & (~is_konami) ) ? intv : 8'h00;

wire [7:0]	idt   = romd | ramd | irqv | vidd | inpd;


T80s z80(
	.RESET_n(~RESET), .CLK_n(CCLK),
	.WAIT_n(~pause), .INT_n(irq_n), .NMI_n(nmi_n), .BUSRQ_n(1'b1), .DI(idt),
	.M1_n(m1), .MREQ_n(me), .IORQ_n(ie), .RD_n(rd), .WR_n(wr), .RFSH_n(rf), .HALT_n(), .BUSAK_n(),
	.A(ad),
	.DO(odt)
);


//--------------------------------------------------
//  VIDEO
//--------------------------------------------------
NRX_VIDEO video(
	.VCLKx4(CLK),  .GAME(GAME), .HPOSi(HP), .VPOSi(VP), .PCLK(PCLK), .POUT(POUT),
	.CPUCLK(CCLK), .CPUADDR(ad),
	.CPUDI(odt),   .CPUDO(viddata),
	.CPUME(mx),    .CPUWE(mw), .CPUDT(vid_Rce),

	.ROMCL(ROMCL),.ROMAD(ROMAD),.ROMDT(ROMDT),.ROMEN(ROMEN),

	.hs_address(hs_address),
	.hs_data_in(hs_data_in),
	.hs_data_out(hs_data_out),
	.hs_write(hs_write),
	.hs_access(hs_access)
);

//--------------------------------------------------
//  SOUND
//--------------------------------------------------
NRX_SOUND	sound(
	.CLK24M(CLK), .CCLK(CCLK), .RESET(RESET), .SND(SND),
	.AD(ad[4:0]), .DI(odt[3:0]),.WR(snd_Wce),
	.BANG(bang),

	.ROMCL(ROMCL),.ROMAD(ROMAD),.ROMDT(ROMDT),.ROMEN(ROMEN)
); 

endmodule
