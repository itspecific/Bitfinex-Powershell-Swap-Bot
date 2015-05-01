$APIKey = ""
$APISecret = ""
$SwapDuration = 7

$VerbosePreference = "continue"
$enc = [system.Text.Encoding]::UTF8

function Bitfinex-GetCurrentSwapOffers {
Write-Verbose "Bitfinex-GetCurrentSwapOffers Called"
$BFXURI = "https://api.bitfinex.com/v1/offers"
$Time = (Get-Date).Ticks
$payloadraw = @{
    request = "/v1/offers"
    nonce = "$Time"
    options = "{}"
}
Bitfinex-PayloadEncoder "$APIKey" "$APISecret" $payloadraw
}

function Bitfinex-GetBalances {
Write-Verbose "Bitfinex-GetBalances Called"
$BFXURI = "https://api.bitfinex.com/v1/balances"
$Time = (Get-Date).Ticks
$payloadraw = @{
    request = "/v1/balances"
    nonce = "$Time"
    options = "{}"
}
Bitfinex-PayloadEncoder "$APIKey" "$APISecret" $payloadraw
}

function Bitfinex-CloseSwapOffers($SwapID) {
Write-Verbose "Bitfinex-CloseSwapOffers Called"
$BFXURI = "https://api.bitfinex.com/v1/offer/cancel"
$Time = (Get-Date).Ticks
$payloadraw = @{
    request = "/v1/offer/cancel"
    nonce = "$Time"
    offer_id = $SwapID
}
Bitfinex-PayloadEncoder "$APIKey" "$APISecret" $payloadraw
}

function Bitfinex-OpenSwapOffer([decimal]$btcamount,[decimal]$swaprate, [int]$perioddays) {
Write-Verbose "Bitfinex-OpenSwapOffer Called"
$BFXURI = "https://api.bitfinex.com/v1/offer/new"
$Time = (Get-Date).Ticks
$payloadraw = @{
    request = "/v1/offer/new"
    nonce = "$Time"
    currency = "btc"
    amount = "$btcamount"
    rate = "$swaprate"
    period = $perioddays
    direction = "lend"
}
Bitfinex-PayloadEncoder "$APIKey" "$APISecret" $payloadraw
}

function Bitfinex-GetCurrentFRR {
Write-Verbose "Bitfinex-GetCurrentFRR Called"
Sleep -Seconds 1
$LendbookAsk = Invoke-RestMethod -Uri https://api.bitfinex.com/v1/lendbook/btc?limit_asks=100 -Method Get | Select asks

foreach ($ask in $LendbookAsk.asks) {
    if ($ask.frr -eq "Yes") {
        $CurrentBTCFrr = $ask.rate
        Write-Verbose ("We found FRR! It is " + $ask.rate + " APR")
        break
        }
}
return [decimal]$CurrentBTCFrr
}

function Bitfinex-GetCurrentBTCValue {
Sleep -Seconds 2
Write-Verbose "Bitfinex-GetCurrentBTCValue Called"
$CurrentLowAsk = Invoke-RestMethod -Uri https://api.bitfinex.com/v1/book/btcusd?limit_asks=1 -Method Get | Select asks -ExpandProperty asks
$CurrentPrice = $CurrentLowAsk.Price
return [decimal]$CurrentPrice
}

Function Bitfinex-PayloadEncoder {
    param([Parameter(Mandatory=$true)]
          [string]$APIKey,
          [string]$APISecret,
          [array]$Payload
          )
Sleep -Seconds 1

$jsonencodedpl = ConvertTo-Json $payloadraw

$byteencodedpl = $enc.GetBytes($jsonencodedpl)

$payload = [System.Convert]::ToBase64String($byteencodedpl)

#We have our payload (hopefully)

$payloadbe = $enc.GetBytes($payload)

$hmacsha = New-Object System.Security.Cryptography.HMACSHA384
$hmacsha.key = $Enc.GetBytes($APISecret)

$signature = $hmacsha.ComputeHash($payloadbe)

$signaturehex = $signature | ForEach-Object { $_.ToString("x2") }
$signaturehex = $signaturehex -join ""

$headers = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
$headers.Add("X-BFX-APIKEY", $APIKey)
$headers.Add("X-BFX-PAYLOAD", $payload)
$headers.Add("X-BFX-SIGNATURE", $signaturehex)

Invoke-RestMethod -Method Post -Uri $BFXURI -Headers $headers
}

do {
$CurrentSwapOffers = Bitfinex-GetCurrentSwapOffers
$CurrentSwapOffers = $CurrentSwapOffers | where {$_.currency -match "BTC"}
[double]$CurrentFRR = Bitfinex-GetCurrentFRR
#How Many in Offers
$sum = $null

foreach ($swap in $CurrentSwapOffers | where {$_.currency -match "BTC"}) {
    $sum = [double]$sum + [double]$swap.remaining_amount
}

$amountinoffers = $sum

#Ok now that we need to get out btc balance in our deposit wallet and see
#if we have more than 50 dollars in btc value
[double]$CurrentValue = Bitfinex-GetCurrentBTCValue
$a = $CurrentValue - 50
$b = ($a / $CurrentValue) * 100
$BTC50USD = [math]::Round((100 - $b) * 0.01,4)
$TargetFRR = [math]::Round(($CurrentFRR - 0.001),3)

#Check and see if we have more that 50 dollars in btc value
#in available offers, and if so, is it over FRR, if it is, we need to close all swaps
if ($amountinoffers -ge $BTC50USD) {
    Write-Verbose "Offers are more than 50 usd value"
    #ok, we have more than that, lets check if they are all just under frr
    foreach ($swapoffer in $CurrentSwapOffers) {
        if ($TargetFRR -ne $swapoffer.rate) {
            $SwapBit = $null
            $SwapBit = 1
            Write-Verbose "We found one over current FRR"
            Break
        }
    }
    if ($SwapBit -eq 1) {
        $SwapBit = $null
        #Ok, so we need to close the open swaps
        ForEach ($swapoffer in $CurrentSwapOffers) {
        Write-Host "Closing swap $swapoffer"
        Bitfinex-CloseSwapOffers $swapoffer.id
     }
    }
}

#OK Done there Lets check our wallet balance, if we have more than 50 dollars in USD valued
#coins we need to reopen at current FRR - 0.0001

$CurrentBlances = Bitfinex-GetBalances
$AvailableBTCBalance = $CurrentBlances | where {$_.type -match "deposit" -and $_.currency -match "btc"} | Select available
$AvailableBTCBalance = $AvailableBTCBalance.available
$ShortAvail = '{0:N2}' -f $AvailableBTCBalance
if ($AvailableBTCBalance -ge $BTC50USD) {
    Write-Verbose "Opening swap btc in the amount of: $ShortAvail at rate: $TargetFRR for $SwapDuration days"
    Bitfinex-OpenSwapOffer $ShortAvail $TargetFRR $SwapDuration
    }
} While ($exit -ne 1)
