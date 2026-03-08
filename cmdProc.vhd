library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.common_pack.all;

entity cmdProc is
  port (
    clk         : in  STD_LOGIC; -- system clock
    reset       : in  STD_LOGIC; -- synchronous reset
    -- UART Rx
    rxnow       : in  STD_LOGIC; -- indicates that data on bus is valid
    rxData      : in  STD_LOGIC_VECTOR (7 downto 0); -- parallel data in
    rxdone      : out STD_LOGIC; -- indicates that data on bus has been read
    ovErr       : in  STD_LOGIC; -- overrun error
    framErr     : in  STD_LOGIC; -- framing error
    -- UART Tx
    txData      : out STD_LOGIC_VECTOR (7 downto 0); -- parallel data out
    txnow       : out STD_LOGIC; -- data ready signal to Tx
    txdone      : in  STD_LOGIC; -- data transmission complete signal from Tx
    -- Data processing
    start       : out STD_LOGIC; -- signal to start data processing
    numWords_bcd: out BCD_ARRAY_TYPE(2 downto 0); -- number of words to process (BCD)
    dataReady   : in  STD_LOGIC; -- signal that new byte of processed data is ready
    byte        : in  STD_LOGIC_VECTOR (7 downto 0); -- processed data byte
    maxIndex    : in  BCD_ARRAY_TYPE(2 downto 0); -- contains peak index in BCD
    dataResults : in  CHAR_ARRAY_TYPE(0 to RESULT_BYTE_NUM-1); -- 7 bytes of processed data
    seqDone     : in  STD_LOGIC
  );
end cmdProc;

architecture FSM of cmdProc is

    type state_type is (
        IDLE,
        IDLE_WAIT_ECHO,
        A_WAIT_ECHO,
        A_GET_D1,
        A_WAIT_ECHO_D1,
        A_GET_D2,
        A_WAIT_ECHO_D2,
        A_GET_D3,
        A_WAIT_ECHO_D3,
        A_START_DP,
        A_WAIT_DATA,
        A_SEND_HI,
        A_WAIT_HI,
        A_SEND_LO,
        A_WAIT_LO,
        A_SEND_SPACE,
        A_WAIT_SPACE,
        A_WAIT_READY_LOW,
        A_DONE_CHECK
    );

    -- State signals
    signal state, next_state : state_type := IDLE;

    -- Data registers
    signal hundreds, next_hundreds : unsigned(3 downto 0) := (others => '0');
    signal tens, next_tens         : unsigned(3 downto 0) := (others => '0');
    signal ones, next_ones         : unsigned(3 downto 0) := (others => '0');
    signal current_byte, next_current_byte : std_logic_vector(7 downto 0) := (others => '0');
    signal echo_char, next_echo_char : std_logic_vector(7 downto 0) := (others => '0');
    signal seq_done_flag : std_logic := '0';
    signal start_reg : std_logic := '0';

    -- Function to convert nibble to ASCII hex character
    function to_hex(nibble : std_logic_vector(3 downto 0)) return std_logic_vector is
    begin
        case nibble is
            when "0000" => return x"30"; -- '0'
            when "0001" => return x"31"; -- '1'
            when "0010" => return x"32"; -- '2'
            when "0011" => return x"33"; -- '3'
            when "0100" => return x"34"; -- '4'
            when "0101" => return x"35"; -- '5'
            when "0110" => return x"36"; -- '6'
            when "0111" => return x"37"; -- '7'
            when "1000" => return x"38"; -- '8'
            when "1001" => return x"39"; -- '9'
            when "1010" => return x"41"; -- 'A'
            when "1011" => return x"42"; -- 'B'
            when "1100" => return x"43"; -- 'C'
            when "1101" => return x"44"; -- 'D'
            when "1110" => return x"45"; -- 'E'
            when "1111" => return x"46"; -- 'F'
            when others => return x"3F"; -- '?'
        end case;
    end function;

begin

    ----------------------------------------------------------------------------
    -- PROCESS 1: State Register (Sequential)
    -- Only updates state on clock edge
    ----------------------------------------------------------------------------
    state_reg: process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                state <= IDLE;
            else
                state <= next_state;
            end if;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- PROCESS 2: Data Registers (Sequential)
    -- Stores BCD digits, current byte, and echo character on clock edge
    ----------------------------------------------------------------------------
    data_reg: process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                hundreds <= (others => '0');
                tens <= (others => '0');
                ones <= (others => '0');
                current_byte <= (others => '0');
                echo_char <= (others => '0');
            else
                hundreds <= next_hundreds;
                tens <= next_tens;
                ones <= next_ones;
                current_byte <= next_current_byte;
                echo_char <= next_echo_char;
            end if;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- PROCESS 3: seqDone Capture (Sequential)
    -- Sticky flag: set whenever seqDone fires, cleared on new command or reset.
    -- This ensures seqDone is never missed regardless of FSM state.
    ----------------------------------------------------------------------------
    seq_done_capture: process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' or next_state = A_START_DP then
                seq_done_flag <= '0';
            elsif seqDone = '1' then
                seq_done_flag <= '1';
            end if;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- PROCESS 3b: Registered start signal (Sequential)
    -- Set when entering A_START_DP, held high throughout processing,
    -- cleared when seq_done_flag fires. Prevents dataConsume re-triggering
    -- while keeping start high so bytes aren't lost during TX states.
    ----------------------------------------------------------------------------
    start_reg_proc: process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                start_reg <= '0';
            elsif next_state = A_START_DP then
                start_reg <= '1';
            elsif seq_done_flag = '1' then
                start_reg <= '0';
            end if;
        end if;
    end process;

    start <= start_reg;

    ----------------------------------------------------------------------------
    -- PROCESS 4: Combinational Logic
    -- Determines next_state and all outputs based on current state and inputs
    -- NO CLOCK - purely combinational
    ----------------------------------------------------------------------------
    comb_logic: process(state, rxnow, rxData, txdone, dataReady, byte,
                        hundreds, tens, ones, current_byte, echo_char,
                        seq_done_flag)
    begin
        -- DEFAULTS (prevents latches!)
        next_state <= state;
        next_hundreds <= hundreds;
        next_tens <= tens;
        next_ones <= ones;
        next_current_byte <= current_byte;
        next_echo_char <= echo_char;

        rxdone <= '0';
        txnow <= '0';
        txData <= (others => '0');
        numWords_bcd(2) <= std_logic_vector(hundreds);
        numWords_bcd(1) <= std_logic_vector(tens);
        numWords_bcd(0) <= std_logic_vector(ones);

        case state is

            when IDLE =>
                if rxnow = '1' then
                    rxdone <= '1';
                    next_echo_char <= rxData;
                    txData <= rxData;
                    txnow <= '1';

                    case rxData is
                        when x"41" => next_state <= A_WAIT_ECHO; -- 'A'
                        when x"61" => next_state <= A_WAIT_ECHO; -- 'a'
                        when others => next_state <= IDLE_WAIT_ECHO;
                    end case;
                end if;

            when IDLE_WAIT_ECHO =>
                txData <= echo_char;
                if txdone = '1' then
                    next_state <= IDLE;
                end if;

            when A_WAIT_ECHO =>
                txData <= echo_char;
                if txdone = '1' then
                    next_state <= A_GET_D1;
                end if;

            when A_GET_D1 =>
                if rxnow = '1' then
                    rxdone <= '1';
                    next_echo_char <= rxData;
                    txData <= rxData;
                    txnow <= '1';

                    if rxData >= x"30" and rxData <= x"39" then
                        next_hundreds <= unsigned(rxData(3 downto 0));
                        next_state <= A_WAIT_ECHO_D1;
                    else
                        next_state <= IDLE_WAIT_ECHO;
                    end if;
                end if;

            when A_WAIT_ECHO_D1 =>
                txData <= echo_char;
                if txdone = '1' then
                    next_state <= A_GET_D2;
                end if;

            when A_GET_D2 =>
                if rxnow = '1' then
                    rxdone <= '1';
                    next_echo_char <= rxData;
                    txData <= rxData;
                    txnow <= '1';

                    if rxData >= x"30" and rxData <= x"39" then
                        next_tens <= unsigned(rxData(3 downto 0));
                        next_state <= A_WAIT_ECHO_D2;
                    else
                        next_state <= IDLE_WAIT_ECHO;
                    end if;
                end if;

            when A_WAIT_ECHO_D2 =>
                txData <= echo_char;
                if txdone = '1' then
                    next_state <= A_GET_D3;
                end if;

            when A_GET_D3 =>
                if rxnow = '1' then
                    rxdone <= '1';
                    next_echo_char <= rxData;
                    txData <= rxData;
                    txnow <= '1';

                    if rxData >= x"30" and rxData <= x"39" then
                        next_ones <= unsigned(rxData(3 downto 0));
                        next_state <= A_WAIT_ECHO_D3;
                    else
                        next_state <= IDLE_WAIT_ECHO;
                    end if;
                end if;

            when A_WAIT_ECHO_D3 =>
                txData <= echo_char;
                if txdone = '1' then
                    next_state <= A_START_DP;
                end if;

            when A_START_DP =>
                next_state <= A_WAIT_DATA;

            when A_WAIT_DATA =>
                if dataReady = '1' then
                    next_current_byte <= byte;
                    next_state <= A_SEND_HI;
                elsif seq_done_flag = '1' then
                    next_state <= A_DONE_CHECK;
                end if;

            when A_SEND_HI =>
                txData <= to_hex(current_byte(7 downto 4));
                txnow <= '1';
                next_state <= A_WAIT_HI;

            when A_WAIT_HI =>
                txData <= to_hex(current_byte(7 downto 4));
                if txdone = '1' then
                    next_state <= A_SEND_LO;
                end if;

            when A_SEND_LO =>
                txData <= to_hex(current_byte(3 downto 0));
                txnow <= '1';
                next_state <= A_WAIT_LO;

            when A_WAIT_LO =>
                txData <= to_hex(current_byte(3 downto 0));
                if txdone = '1' then
                    next_state <= A_SEND_SPACE;
                end if;

            when A_SEND_SPACE =>
                txData <= x"20";  -- ASCII space
                txnow <= '1';
                next_state <= A_WAIT_SPACE;

            when A_WAIT_SPACE =>
                txData <= x"20";
                if txdone = '1' then
                    next_state <= A_WAIT_READY_LOW;
                end if;

            when A_WAIT_READY_LOW =>
                if dataReady = '0' then
                    next_state <= A_WAIT_DATA;
                end if;

            when A_DONE_CHECK =>
                if dataReady = '1' then
                    next_current_byte <= byte;
                    next_state <= A_SEND_HI;
                else
                    next_state <= IDLE;
                end if;

            when others =>
                next_state <= IDLE;

        end case;
    end process;

end FSM;
