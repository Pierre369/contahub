import { createClient } from '@supabase/supabase-js'

export default async function handler(req, res) {
  // ===== WEBHOOK DO MERCADO PAGO =====
  // Só aceita POST
  if (req.method !== 'POST') {
    return res.status(405).json({ erro: 'Método não permitido' })
  }
  
  const { action, data } = req.body || {}
  
  // Mercado Pago envia notification.type=payment e notification.topic=payment
  const isPaymentNotification = 
    (action === 'payment.created' || action === 'payment.updated') ||
    (data && data.id)
  
  if (!isPaymentNotification) {
    return res.status(200).json({ received: true, ignored: 'not a payment notification' })
  }
  
  const paymentId = data ? data.id : (req.body.id || null)
  if (!paymentId) {
    return res.status(400).json({ erro: 'payment id não encontrado' })
  }
  
  // BUSCAR PAGAMENTO DIRETO NA API DO MP (nunca confiar no body do webhook)
  const mpRes = await fetch('https://api.mercadopago.com/v1/payments/' + paymentId, {
    headers: { Authorization: 'Bearer ' + process.env.MP_ACCESS_TOKEN }
  })
  
  if (!mpRes.ok) {
    return res.status(404).json({ erro: 'Pagamento não encontrado no MP' })
  }
  
  const payment = await mpRes.json()
  
  // Verificar se está aprovado
  const status = payment.status // approved, pending, rejected, cancelled, refunded, charged_back
  const externalRef = payment.external_reference // orderId do Supabase
  
  if (!externalRef) {
    return res.status(200).json({ received: true, ignored: 'no external_reference' })
  }
  
  // Atualizar pedido no Supabase usando SERVICE_ROLE_KEY
  const supabase = createClient(
    process.env.SUPABASE_URL,
    process.env.SUPABASE_SERVICE_ROLE_KEY
  )
  
  // Buscar o pedido pelo external_reference (orderId)
  const { data: orderData, error: orderError } = await supabase
    .from('orders')
    .select('id, status, mp_payment_id')
    .eq('id', externalRef)
    .single()
  
  if (orderError || !orderData) {
    return res.status(404).json({ erro: 'Pedido não encontrado', orderId: externalRef })
  }
  
  // Se já tem o mesmo mp_payment_id e status, ignora
  if (orderData.mp_payment_id === paymentId && orderData.status === status) {
    return res.status(200).json({ received: true, ignored: 'already processed' })
  }
  
  // Atualizar o pedido com mp_payment_id e status
  const updateData = {
    mp_payment_id: paymentId,
    status: status === 'approved' ? 'pago' : status
  }
  
  const { error: updateError } = await supabase
    .from('orders')
    .update(updateData)
    .eq('id', externalRef)
  
  if (updateError) {
    console.error('Erro ao atualizar pedido:', updateError)
    return res.status(500).json({ erro: 'Erro ao atualizar pedido', details: updateError.message })
  }
  
  console.log('Webhook MP: pedido ' + externalRef + ' atualizado para ' + status)
  res.status(200).json({ 
    received: true, 
    orderId: externalRef, 
    mp_payment_id: paymentId,
    status: status
  })
}
